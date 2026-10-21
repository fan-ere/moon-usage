///|
test "long reversed history retains only latest baseline in the trace" {
  let events : Array[@moon-usage.Event] = []
  for tick = 9999; tick >= 0; tick = tick - 1 {
    events.push(event("history-\{tick}", tick, tick * 2))
  }
  events.push(event("reading", 10000, 20005))
  events.push(event("history-9999", 9999, 19998))
  events.push(event("end", 10001, 900000000))
  events.push({
    id: "other-account",
    account: "b",
    meter: "m",
    time: 9999,
    value: 999,
  })
  let u = @moon-usage.aggregate(
    events,
    "a",
    "m",
    10000,
    10001,
    Counter(RejectDecrease),
  ).unwrap()
  assert_eq(u.quantity, 7)
  assert_eq(u.baseline_id, Some("history-9999"))
  assert_eq(u.accepted_events, 1)
  assert_eq(u.duplicate_events, 0)
  assert_eq(u.event_ids, ["reading"])
  assert_eq(u.counter_deltas[0].previous, 19998)
  assert_eq(events.length(), 10004)
  assert_eq(events[0].id, "history-9999")
}

///|
test "historical ambiguity chooses earliest tick regardless of input order" {
  let events = [
    event("new-baseline", 9, 100),
    event("b1", 5, 10),
    event("b2", 5, 10),
    event("a1", 2, 2),
    event("a2", 2, 3),
    event("reading1", 11, 110),
    event("reading2", 11, 120),
  ]
  for offset = 0; offset < events.length(); offset = offset + 1 {
    let reordered = Array::makei(events.length(), fn(i) {
      events[(i + offset) % events.length()]
    })
    assert_eq(
      @moon-usage.aggregate(reordered, "a", "m", 10, 20, Counter(RestartAtZero)).unwrap_err(),
      @moon-usage.UsageError::AmbiguousReading(2),
    )
  }
}

///|
test "global validation errors still precede historical ambiguity" {
  let events = [event("h1", 1, 1), event("h2", 1, 2)]
  events.push(event("outside", 100, 1))
  events.push(event("outside", 100, 2))
  assert_eq(
    @moon-usage.aggregate(events, "a", "m", 10, 20, Counter(RejectDecrease)).unwrap_err(),
    @moon-usage.UsageError::DuplicateConflict("outside"),
  )
  events.pop() |> ignore
  events.push(event("invalid", 100, -1))
  assert_eq(
    @moon-usage.aggregate(events, "a", "m", 10, 20, Counter(RejectDecrease)).unwrap_err(),
    @moon-usage.UsageError::InvalidValue("invalid"),
  )
}

///|
test "counter replay permutations preserve analytic reset and baseline results" {
  for initial = 0; initial < 16; initial = initial + 1 {
    // The older reading decreases before the baseline. Only period deltas count.
    let events = [
      event("older", 1, 1000),
      event("baseline", 9, initial),
      event("first", 10, initial + 7),
      event("reset", 11, 2),
      event("last", 19, 5),
      event("end", 20, 999),
      event("reset", 11, 2),
      event("baseline", 9, initial),
    ]
    for offset = 0; offset < events.length(); offset = offset + 1 {
      let reordered = Array::makei(events.length(), fn(i) {
        events[(events.length() - 1 - i + offset) % events.length()]
      })
      let u = @moon-usage.aggregate(
        reordered,
        "a",
        "m",
        10,
        20,
        Counter(RestartAtZero),
      ).unwrap()
      assert_eq(u.quantity, 12) // Seven before reset, two at reset, three after it.
      assert_eq(u.reset_events, 1)
      assert_eq(u.duplicate_events, 1)
      assert_eq(u.baseline_id, Some("baseline"))
      assert_eq(u.event_ids, ["first", "reset", "last"])
      assert_eq(u.counter_deltas.map(fn(d) { d.delta }), [7, 2, 3])
      assert_eq(
        @moon-usage.aggregate(
          reordered,
          "a",
          "m",
          10,
          20,
          Counter(RejectDecrease),
        ).unwrap_err(),
        @moon-usage.UsageError::CounterDecreased("reset"),
      )
    }
  }
}
