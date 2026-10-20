///|
fn event(id : String, time : Int32, value : Int32) -> @moon-usage.Event {
  { id, account: "a", meter: "m", time, value, }
}

///|
fn plan(
  pricing~ : @moon-usage.Pricing = Graduated,
  rounding~ : @moon-usage.Rounding = HalfEven,
  per_units~ : Int32 = 1,
) -> @moon-usage.Plan {
  {
    currency: "CNY",
    pricing,
    rounding,
    per_units,
    base_minor: 5,
    tiers: [{ up_to: Some(10), rate: 3, }, { up_to: None, rate: 2, }],
  }
}

///|
test "sum isolates account meter and half-open period, deduplicates retries" {
  let e = event("b", 10, 7)
  let events = [
    event("before", 9, 500),
    event("end", 20, 500),
    e,
    event("c", 19, 8),
    e,
    { id: "other", account: "b", meter: "m", time: 12, value: 999, },
    { id: "other-meter", account: "a", meter: "n", time: 12, value: 999, },
  ]
  let u = @moon-usage.aggregate(events, "a", "m", 10, 20, Sum).unwrap()
  assert_eq(u.quantity, 15)
  assert_eq(u.accepted_events, 2)
  assert_eq(u.duplicate_events, 1)
  assert_eq(u.event_ids, ["b", "c"])
  assert_eq(events.length(), 7)
}

///|
test "input permutations yield the same trace and quantity" {
  let a = event("a", 11, 2)
  let b = event("b", 10, 3)
  let c = event("c", 10, 4)
  let x = @moon-usage.aggregate([a, b, c, b], "a", "m", 10, 20, Sum).unwrap()
  let y = @moon-usage.aggregate([c, b, b, a], "a", "m", 10, 20, Sum).unwrap()
  assert_eq(x.quantity, y.quantity)
  assert_eq(x.event_ids, ["b", "c", "a"])
  assert_eq(x.event_ids, y.event_ids)
  assert_eq(x.duplicate_events, y.duplicate_events)
}

///|
test "conflicting retry fails even outside window and across accounts" {
  let result = @moon-usage.aggregate(
    [event("id", 1, 1), event("id", 1, 2)],
    "a",
    "m",
    10,
    20,
    Sum,
  )
  assert_eq(
    result.unwrap_err(),
    @moon-usage.UsageError::DuplicateConflict("id"),
  )
  assert_eq(
    @moon-usage.aggregate(
      [
        event("id", 11, 1),
        { id: "id", account: "b", meter: "m", time: 11, value: 1, },
      ],
      "a",
      "m",
      10,
      20,
      Sum,
    ).unwrap_err(),
    @moon-usage.UsageError::DuplicateConflict("id"),
  )
}

///|
test "invalid periods identities and values are rejected" {
  for (start, end) in [(-1, 1), (1, 1), (2, 1)] {
    assert_eq(
      @moon-usage.aggregate([], "a", "m", start, end, Sum).unwrap_err(),
      @moon-usage.UsageError::InvalidPeriod,
    )
  }
  assert_eq(
    @moon-usage.aggregate([], "", "m", 1, 2, Sum).unwrap_err(),
    @moon-usage.UsageError::EmptyIdentity,
  )
  for e in [event("x", -1, 1), event("x", 1, -1), event("x", 1, 1000000001)] {
    assert_eq(
      @moon-usage.aggregate([e], "a", "m", 1, 2, Sum).unwrap_err(),
      @moon-usage.UsageError::InvalidValue("x"),
    )
  }
  assert_eq(
    @moon-usage.aggregate([event("", 1, 1)], "a", "m", 1, 2, Sum).unwrap_err(),
    @moon-usage.UsageError::EmptyIdentity,
  )
}

///|
test "sum quantity cap refuses overflow" {
  assert_eq(
    @moon-usage.aggregate(
      [event("a", 1, 1000000000), event("b", 1, 1)],
      "a",
      "m",
      1,
      2,
      Sum,
    ).unwrap_err(),
    @moon-usage.UsageError::QuantityLimit,
  )
}

///|
test "peak and last differ; same timestamp is allowed only for peak" {
  let events = [event("a", 10, 8), event("b", 11, 3)]
  assert_eq(
    @moon-usage.aggregate(events, "a", "m", 10, 20, Peak).unwrap().quantity,
    8,
  )
  assert_eq(
    @moon-usage.aggregate(events, "a", "m", 10, 20, Last).unwrap().quantity,
    3,
  )
  let ties = [event("a", 10, 8), event("b", 10, 3)]
  assert_eq(
    @moon-usage.aggregate(ties, "a", "m", 10, 20, Peak).unwrap().quantity,
    8,
  )
  assert_eq(
    @moon-usage.aggregate(ties, "a", "m", 10, 20, Last).unwrap_err(),
    @moon-usage.UsageError::AmbiguousReading(10),
  )
}

///|
test "empty regular meters give zero" {
  for mode in [@moon-usage.Aggregation::Sum, Peak, Last] {
    let u = @moon-usage.aggregate([], "a", "m", 0, 10, mode).unwrap()
    assert_eq(u.quantity, 0)
    assert_eq(u.accepted_events, 0)
    assert_eq(u.baseline_id, None)
  }
}

///|
test "counter selects latest baseline, sums deltas at reading timestamps" {
  let events = [
    event("old", 1, 10),
    event("baseline", 9, 100),
    event("next", 10, 130),
    event("last", 19, 150),
    event("end", 20, 900),
  ]
  let u = @moon-usage.aggregate(
    events,
    "a",
    "m",
    10,
    20,
    Counter(RejectDecrease),
  ).unwrap()
  assert_eq(u.quantity, 50)
  assert_eq(u.baseline_id, Some("baseline"))
  assert_eq(u.event_ids, ["next", "last"])
  assert_eq(u.reset_events, 0)
}

///|
test "counter needs baseline even when empty or first reading at start" {
  for events in [[], [event("a", 10, 50)]] {
    assert_eq(
      @moon-usage.aggregate(events, "a", "m", 10, 20, Counter(RejectDecrease)).unwrap_err(),
      @moon-usage.UsageError::MissingBaseline,
    )
  }
  assert_eq(
    @moon-usage.aggregate(
      [event("b", 9, 50)],
      "a",
      "m",
      10,
      20,
      Counter(RejectDecrease),
    ).unwrap().quantity,
    0,
  )
}

///|
test "counter reset is an explicit business policy" {
  let events = [
    event("baseline", 9, 100),
    event("a", 11, 130),
    event("reset", 12, 4),
    event("b", 13, 9),
  ]
  assert_eq(
    @moon-usage.aggregate(events, "a", "m", 10, 20, Counter(RejectDecrease)).unwrap_err(),
    @moon-usage.UsageError::CounterDecreased("reset"),
  )
  let u = @moon-usage.aggregate(
    events,
    "a",
    "m",
    10,
    20,
    Counter(RestartAtZero),
  ).unwrap()
  assert_eq(u.quantity, 39)
  assert_eq(u.reset_events, 1)
}

///|
test "counter ambiguous historical baselines fail rather than guess" {
  assert_eq(
    @moon-usage.aggregate(
      [event("a", 9, 100), event("b", 9, 101)],
      "a",
      "m",
      10,
      20,
      Counter(RejectDecrease),
    ).unwrap_err(),
    @moon-usage.UsageError::AmbiguousReading(9),
  )
}

///|
test "counter quantity cap survives multiple resets" {
  assert_eq(
    @moon-usage.aggregate(
      [event("baseline", 0, 0), event("a", 1, 1000000000), event("b", 2, 1)],
      "a",
      "m",
      1,
      3,
      Counter(RestartAtZero),
    ).unwrap_err(),
    @moon-usage.UsageError::QuantityLimit,
  )
}

///|
test "graduated vs volume use different tier semantics at boundaries" {
  for
    (q, graduated, volume) in [
      (0, 5L, 5L),
      (10, 35L, 35L),
      (11, 37L, 27L),
      (20, 55L, 45L),
    ] {
    assert_eq(@moon-usage.rate(plan(), q).unwrap().total_minor, graduated)
    assert_eq(
      @moon-usage.rate(plan(pricing=Volume), q).unwrap().total_minor,
      volume,
    )
  }
  let q = @moon-usage.rate(plan(), 11).unwrap()
  assert_eq(q.lines.length(), 2)
  assert_eq(q.lines[0].quantity, 10)
  assert_eq(q.lines[1].quantity, 1)
  assert_eq(q.usage_numerator, 32L)
}

///|
test "round exact fractional sum once, not each tier" {
  let p : @moon-usage.Plan = {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 2,
    base_minor: 0,
    tiers: [{ up_to: Some(1), rate: 1, }, { up_to: None, rate: 1, }],
  }
  let q = @moon-usage.rate(p, 2).unwrap()
  assert_eq(q.lines[0].numerator, 1L)
  assert_eq(q.lines[1].numerator, 1L)
  assert_eq(q.usage_minor, 1L)
}

///|
test "half even ties go to even; up and down handle remainders" {
  for
    (q, even, up, down) in [
      (0, 0L, 0L, 0L),
      (1, 0L, 1L, 0L),
      (2, 1L, 1L, 1L),
      (3, 2L, 2L, 1L),
      (5, 2L, 3L, 2L),
      (7, 4L, 4L, 3L),
    ] {
    for
      (mode, want) in [
        (@moon-usage.Rounding::HalfEven, even),
        (Up, up),
        (Down, down),
      ] {
      let p : @moon-usage.Plan = {
        currency: "X",
        pricing: Graduated,
        rounding: mode,
        per_units: 2,
        base_minor: 0,
        tiers: [{ up_to: None, rate: 1, }],
      }
      assert_eq(@moon-usage.rate(p, q).unwrap().total_minor, want)
    }
  }
}

///|
test "maximum supported operands stay exact across targets" {
  let p : @moon-usage.Plan = {
    currency: "X",
    pricing: Graduated,
    rounding: Up,
    per_units: 1,
    base_minor: 1000000000,
    tiers: [{ up_to: None, rate: 1000000000, }],
  }
  assert_eq(
    @moon-usage.rate(p, 1000000000).unwrap().total_minor,
    1000000001000000000L,
  )
  assert_eq(
    @moon-usage.rate(p, -1).unwrap_err(),
    @moon-usage.UsageError::QuantityLimit,
  )
  assert_eq(
    @moon-usage.rate(p, 1000000001).unwrap_err(),
    @moon-usage.UsageError::QuantityLimit,
  )
}

///|
test "invalid plan structure is rejected before charging" {
  let invalid_tiers : Array[Array[@moon-usage.Tier]] = [
    [],
    [{ up_to: Some(1), rate: 1, }],
    [{ up_to: None, rate: 1, }, { up_to: None, rate: 1, }],
    [
      { up_to: Some(2), rate: 1, },
      { up_to: Some(2), rate: 1, },
      { up_to: None, rate: 1, },
    ],
    [{ up_to: Some(0), rate: 1, }, { up_to: None, rate: 1, }],
    [{ up_to: Some(1000000001), rate: 1, }, { up_to: None, rate: 1, }],
    [{ up_to: None, rate: -1, }],
    [{ up_to: None, rate: 1000000001, }],
  ]
  for tiers in invalid_tiers {
    let p : @moon-usage.Plan = { ..plan(), tiers, }
    assert_true(@moon-usage.validate_plan(p) is Err(_))
    assert_true(@moon-usage.rate(p, 0) is Err(_))
  }
  for
    p in [
      @moon-usage.Plan::{ ..plan(), per_units: 0, },
      { ..plan(), per_units: 1000000001, },
      { ..plan(), base_minor: -1, },
      { ..plan(), base_minor: 1000000001, },
      { ..plan(), currency: "", },
    ] {
    assert_true(@moon-usage.validate_plan(p) is Err(_))
  }
}

///|
test "unreached invalid tier still fails" {
  let p : @moon-usage.Plan = {
    ..plan(),
    tiers: [{ up_to: Some(100), rate: 1, }, { up_to: None, rate: -1, }],
  }
  assert_true(@moon-usage.rate(p, 1) is Err(_))
}

///|
test "small exhaustive rating oracle and charge conservation" {
  // Independent per-unit enumeration, rather than the production band-splitting algorithm.
  for first_rate = 0; first_rate <= 4; first_rate = first_rate + 1 {
    for second_rate = 0; second_rate <= 4; second_rate = second_rate + 1 {
      for quantity = 0; quantity <= 24; quantity = quantity + 1 {
        let p : @moon-usage.Plan = {
          ..plan(),
          tiers: [
            { up_to: Some(10), rate: first_rate, },
            { up_to: None, rate: second_rate, },
          ],
        }
        let mut oracle = 5L
        for unit = 1; unit <= quantity; unit = unit + 1 {
          oracle += (if unit <= 10 { first_rate } else { second_rate }).to_int64()
        }
        let q = @moon-usage.rate(p, quantity).unwrap()
        assert_eq(q.total_minor, oracle)
        let mut count = 0
        let mut numerator = 0L
        for line in q.lines {
          count += line.quantity
          numerator += line.numerator
        }
        assert_eq(count, quantity)
        assert_eq(numerator, q.usage_numerator)
      }
    }
  }
}

///|
test "end to end and late-arrival replay is stateless" {
  let first = @moon-usage.bill(
    [event("a", 11, 10)],
    "a",
    "m",
    10,
    20,
    Sum,
    plan(),
  ).unwrap()
  let revised = @moon-usage.bill(
    [event("a", 11, 10), event("b", 12, 5)],
    "a",
    "m",
    10,
    20,
    Sum,
    plan(),
  ).unwrap()
  assert_eq(first.quote.total_minor, 35L)
  assert_eq(revised.quote.total_minor, 45L)
  assert_eq(revised.quote.total_minor - first.quote.total_minor, 10L)
  assert_eq(first.usage.event_ids, ["a"])
}

///|
test "bill propagates usage and plan errors" {
  assert_eq(
    @moon-usage.bill([], "a", "m", 0, 0, Sum, plan()).unwrap_err(),
    @moon-usage.UsageError::InvalidPeriod,
  )
  assert_true(
    @moon-usage.bill([], "a", "m", 0, 1, Sum, { ..plan(), per_units: 0, })
    is Err(_),
  )
}
