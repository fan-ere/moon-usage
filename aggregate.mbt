///|
/// Validate and deduplicate the entire supplied batch, then isolate account/meter.
/// Duplicate IDs are global within this batch, even outside the selected window.
pub fn aggregate(
  events : Array[Event],
  account : String,
  meter : String,
  start : Int32,
  end : Int32,
  mode : Aggregation,
) -> Result[Usage, UsageError] {
  if start < 0 || end <= start {
    return Err(InvalidPeriod)
  }
  if account == "" || meter == "" {
    return Err(EmptyIdentity)
  }
  let seen : Map[String, Event] = Map([])
  let selected : Array[Event] = []
  let needs_history = mode is Counter(_)
  let mut duplicates = 0
  for event in events {
    if event.id == "" || event.account == "" || event.meter == "" {
      return Err(EmptyIdentity)
    }
    if event.time < 0 || event.value < 0 || event.value > 1000000000 {
      return Err(InvalidValue(event.id))
    }
    match seen.get(event.id) {
      Some(old) => {
        if old != event {
          return Err(DuplicateConflict(event.id))
        }
        if event.account == account &&
          event.meter == meter &&
          event.time >= start &&
          event.time < end {
          duplicates += 1
        }
      }
      None => {
        seen[event.id] = event
        if event.account == account &&
          event.meter == meter &&
          event.time < end &&
          (needs_history || event.time >= start) {
          selected.push(event)
        }
      }
    }
  }
  selected.sort_by(fn(a, b) {
    if a.time == b.time {
      a.id.compare(b.id)
    } else {
      a.time.compare(b.time)
    }
  })
  let mut quantity = 0
  let mut resets = 0
  let mut baseline : Event? = None
  let ids : Array[String] = []
  let counter_deltas : Array[CounterDelta] = []
  match mode {
    Counter(_) => {
      // A value at start is an interval-end reading, so require a strictly earlier baseline.
      for event in selected {
        if event.time < start {
          baseline = Some(event)
        }
      }
      // Ambiguous same-tick readings are refused, including candidate baselines.
      for i = 1; i < selected.length(); i = i + 1 {
        if selected[i].time == selected[i - 1].time {
          return Err(AmbiguousReading(selected[i].time))
        }
      }
      if baseline is None {
        return Err(MissingBaseline)
      }
    }
    Last =>
      for i = 1; i < selected.length(); i = i + 1 {
        if selected[i].time >= start && selected[i].time == selected[i - 1].time {
          return Err(AmbiguousReading(selected[i].time))
        }
      }
    _ => ()
  }
  let mut previous = match baseline {
    Some(e) => e.value
    None => 0
  }
  for event in selected {
    if event.time < start {
      continue
    }
    ids.push(event.id)
    match mode {
      Sum => {
        if event.value > 1000000000 - quantity {
          return Err(QuantityLimit)
        }
        quantity += event.value
      }
      Peak => if event.value > quantity { quantity = event.value }
      Last => quantity = event.value
      Counter(policy) => {
        let reset = event.value < previous
        let delta = if reset {
          match policy {
            RejectDecrease => return Err(CounterDecreased(event.id))
            RestartAtZero => {
              resets += 1
              event.value
            }
          }
        } else {
          event.value - previous
        }
        if delta > 1000000000 - quantity {
          return Err(QuantityLimit)
        }
        quantity += delta
        counter_deltas.push({
          event_id: event.id,
          time: event.time,
          previous,
          reading: event.value,
          delta,
          reset,
        })
        previous = event.value
      }
    }
  }
  Ok({
    aggregation: mode,
    quantity,
    accepted_events: ids.length(),
    duplicate_events: duplicates,
    reset_events: resets,
    baseline_id: match baseline {
      Some(e) => Some(e.id)
      None => None
    },
    event_ids: ids,
    counter_deltas,
  })
}
