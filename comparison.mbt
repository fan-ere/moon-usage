///|
pub(all) enum ComparisonError {
  InvalidBefore(ReplayError)
  InvalidAfter(ReplayError)
  DifferentContext(String)
  InputRevisionRequired
  PlanRevisionRequired
} derive(Eq, Debug)

///|
pub extend ComparisonError with Eq::{equal, not_equal}

///|
pub extend ComparisonError with @debug.Debug::{to_repr}

///|
/// Changes concern the complete raw batch, including events outside this bill.
pub(all) struct BillChange {
  currency : String
  before_input_revision : String
  after_input_revision : String
  before_plan_revision : String
  after_plan_revision : String
  quantity_delta : Int32
  total_minor_delta : Int64
  added_event_ids : Array[String]
  removed_event_ids : Array[String]
  changed_event_ids : Array[String]
  plan_changed : Bool
} derive(Debug)

///|
pub extend BillChange with @debug.Debug::{to_repr}

///|
/// Verify both records before subtracting; never subtract different currencies.
pub fn compare_snapshots(
  before : Snapshot,
  after : Snapshot,
) -> Result[BillChange, ComparisonError] {
  let (old, old_bill) = match verify_document(before.to_json()) {
    Ok(value) => value
    Err(error) => return Err(InvalidBefore(error))
  }
  let (new, new_bill) = match verify_document(after.to_json()) {
    Ok(value) => value
    Err(error) => return Err(InvalidAfter(error))
  }
  for
    (key, same) in [
      ("account", old.account == new.account),
      ("meter", old.meter == new.meter),
      ("start", old.start == new.start),
      ("end", old.end == new.end),
      ("aggregation", old.aggregation == new.aggregation),
      ("currency", old.plan.currency == new.plan.currency),
    ] {
    if !same {
      return Err(DifferentContext(key))
    }
  }
  if old.events != new.events && old.input_revision == new.input_revision {
    return Err(InputRevisionRequired)
  }
  let plan_changed = old.plan.currency != new.plan.currency ||
    old.plan.pricing != new.plan.pricing ||
    old.plan.rounding != new.plan.rounding ||
    old.plan.per_units != new.plan.per_units ||
    old.plan.base_minor != new.plan.base_minor ||
    old.plan.tiers != new.plan.tiers
  if plan_changed && old.plan_revision == new.plan_revision {
    return Err(PlanRevisionRequired)
  }
  let old_events : Map[String, Event] = Map([])
  let new_events : Map[String, Event] = Map([])
  for event in old.events {
    old_events[event.id] = event
  }
  for event in new.events {
    new_events[event.id] = event
  }
  let added : Array[String] = []
  let removed : Array[String] = []
  let changed : Array[String] = []
  for id, event in new_events {
    match old_events.get(id) {
      None => added.push(id)
      Some(previous) => if previous != event { changed.push(id) }
    }
  }
  for id in old_events.keys() {
    if !new_events.contains(id) {
      removed.push(id)
    }
  }
  added.sort()
  removed.sort()
  changed.sort()
  Ok({
    currency: new.plan.currency,
    before_input_revision: old.input_revision,
    after_input_revision: new.input_revision,
    before_plan_revision: old.plan_revision,
    after_plan_revision: new.plan_revision,
    quantity_delta: new_bill.usage.quantity - old_bill.usage.quantity,
    total_minor_delta: new_bill.quote.total_minor - old_bill.quote.total_minor,
    added_event_ids: added,
    removed_event_ids: removed,
    changed_event_ids: changed,
    plan_changed,
  })
}

///|
pub fn BillChange::to_json(self : BillChange) -> Json {
  Json({
    "currency": Json(self.currency),
    "before_input_revision": Json(self.before_input_revision),
    "after_input_revision": Json(self.after_input_revision),
    "before_plan_revision": Json(self.before_plan_revision),
    "after_plan_revision": Json(self.after_plan_revision),
    "quantity_delta": Json(self.quantity_delta),
    "total_minor_delta": Json(self.total_minor_delta.to_string()),
    "added_event_ids": Json(self.added_event_ids),
    "removed_event_ids": Json(self.removed_event_ids),
    "changed_event_ids": Json(self.changed_event_ids),
    "plan_changed": Json(self.plan_changed),
  })
}
