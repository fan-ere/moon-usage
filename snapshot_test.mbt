///|
fn replay_input() -> @moon-usage.BillInput {
  {
    input_revision: "events-1",
    plan_revision: "plan-1",
    events: [event("first", 11, 10), event("first", 11, 10)],
    account: "a",
    meter: "m",
    start: 10,
    end: 20,
    aggregation: Sum,
    plan: plan(),
  }
}

///|
fn object(value : Json) -> Map[String, Json] {
  guard value is Object(fields) else { abort("Expected object") }
  fields
}

///|
test "snapshot preserves full inputs duplicates and unreached tiers across serialization" {
  let input = replay_input()
  input.events.push({
    id: "unrelated",
    account: "b",
    meter: "m",
    time: 1,
    value: 8,
  })
  let snapshot = @moon-usage.capture(input).unwrap()
  let decoded = @moon-usage.Snapshot::from_string(snapshot.to_string()).unwrap()
  let replayed = decoded.replay().unwrap()
  assert_eq(replayed.quote.total_minor, 35L)
  assert_eq(replayed.usage.duplicate_events, 1)
  assert_eq(replayed.to_json(), snapshot.replay().unwrap().to_json())
  let saved = @moon-usage.BillInput::from_json(
    object(snapshot.to_json())["input"],
  ).unwrap()
  assert_eq(saved.events, input.events)
  assert_eq(saved.plan.tiers, input.plan.tiers)
  assert_eq(saved.input_revision, "events-1")
  assert_eq(saved.plan_revision, "plan-1")
}

///|
test "snapshot freezes mutable input and returns independent JSON objects" {
  let input = replay_input()
  let snapshot = @moon-usage.capture(input).unwrap()
  input.events.push(event("late", 12, 5))
  input.plan.tiers[0] = { up_to: Some(10), rate: 99, }
  let changed = snapshot.to_json()
  object(object(changed)["bill"])["account"] = Json("edited")
  assert_eq(snapshot.replay().unwrap().quote.total_minor, 35L)
  assert_eq(snapshot.replay().unwrap().usage.event_ids, ["first"])
  assert_eq(
    @moon-usage.Snapshot::from_json(changed).unwrap_err(),
    @moon-usage.ReplayError::BillMismatch,
  )
}

///|
test "replay checks every bill field rather than only total amount" {
  let snapshot = @moon-usage.capture(replay_input()).unwrap()
  for
    (key, value) in [
      ("quantity", Json(999)),
      ("total_minor", Json(35)),
      ("rounding", Json("up")),
      ("lines", Json::array([])),
    ] {
    let saved = snapshot.to_json()
    let q = object(object(object(saved)["bill"])["quote"])
    q[key] = value
    assert_eq(
      @moon-usage.Snapshot::from_json(saved).unwrap_err(),
      @moon-usage.ReplayError::BillMismatch,
    )
  }
  let saved = snapshot.to_json()
  object(object(object(saved)["bill"])["usage"])["duplicate_events"] = Json(0)
  assert_eq(
    @moon-usage.Snapshot::from_json(saved).unwrap_err(),
    @moon-usage.ReplayError::BillMismatch,
  )
}

///|
test "changed event or plan recomputes and rejects stale bill" {
  let snapshot = @moon-usage.capture(replay_input()).unwrap()
  for change_plan in [false, true] {
    let saved = snapshot.to_json()
    let input = object(object(saved)["input"])
    if change_plan {
      object(input["plan"])["base_minor"] = Json(99)
    } else {
      input["events"] = Json([
        Json({
          "id": Json("first"),
          "account": Json("a"),
          "meter": Json("m"),
          "time": Json(11),
          "value": Json(20),
        }),
      ])
    }
    assert_eq(
      @moon-usage.Snapshot::from_json(saved).unwrap_err(),
      @moon-usage.ReplayError::BillMismatch,
    )
  }
}

///|
test "replay rejects unknown schema rules and unexpected fields" {
  let snapshot = @moon-usage.capture(replay_input()).unwrap()
  for
    (key, error) in [
      ("schema", @moon-usage.ReplayError::UnsupportedSchema("next")),
      ("rules", @moon-usage.ReplayError::UnsupportedRules("next")),
    ] {
    let saved = snapshot.to_json()
    object(saved)[key] = Json("next")
    assert_eq(@moon-usage.Snapshot::from_json(saved).unwrap_err(), error)
  }
  let saved = snapshot.to_json()
  object(saved)["ignored"] = Json(true)
  assert_true(
    @moon-usage.Snapshot::from_json(saved).unwrap_err() is InvalidSnapshot(_),
  )
}

///|
test "input decoder refuses fractions overflow strings and invalid enum values" {
  for
    bad in [
      Json(1.5),
      Json(-1),
      Json(2147483648.0),
      Json("10"),
      Json::number(0.0 / 0.0),
    ] {
    let input = replay_input().to_json()
    object(input)["start"] = bad
    assert_true(
      @moon-usage.BillInput::from_json(input).unwrap_err() is InvalidSnapshot(_),
    )
  }
  for
    (key, bad) in [
      ("aggregation", Json("average")),
      ("reset_policy", Json("restart_at_zero")),
      ("input_revision", Json("")),
      ("plan_revision", Json("")),
    ] {
    let input = replay_input().to_json()
    object(input)[key] = bad
    assert_true(
      @moon-usage.BillInput::from_json(input).unwrap_err() is InvalidSnapshot(_),
    )
  }
}

///|
test "capture and replay propagate calculation errors including unused invalid tiers" {
  let input = replay_input()
  assert_eq(
    @moon-usage.capture({ ..input, end: 10, }).unwrap_err(),
    @moon-usage.ReplayError::CalculationFailed(InvalidPeriod),
  )
  let snapshot = @moon-usage.capture(input).unwrap()
  let saved = snapshot.to_json()
  object(object(object(saved)["input"])["plan"])["tiers"] = Json([
    Json({ "up_to": Json(100), "rate": Json(3) }),
    Json({ "up_to": Json::null(), "rate": Json(1000000001) }),
  ])
  assert_true(
    @moon-usage.Snapshot::from_json(saved).unwrap_err()
    is CalculationFailed(InvalidPlan(_)),
  )
}

///|
test "snapshot counter modes peak last and rounding policies round trip" {
  for
    mode in [
      @moon-usage.Aggregation::Sum,
      Peak,
      Last,
      Counter(RejectDecrease),
      Counter(RestartAtZero),
    ] {
    for pricing in [@moon-usage.Pricing::Graduated, Volume] {
      for rounding in [@moon-usage.Rounding::Down, Up, HalfEven] {
        let input : @moon-usage.BillInput = {
          ..replay_input(),
          aggregation: mode,
          events: [
            event("base", 9, 3),
            event("r1", 11, 10),
            event("r2", 19, 15),
          ],
          plan: { ..plan(), pricing, rounding, per_units: 7, },
        }
        let snapshot = @moon-usage.capture(input).unwrap()
        let restored = @moon-usage.Snapshot::from_string(snapshot.to_string()).unwrap()
        assert_eq(
          restored.replay().unwrap().to_json(),
          snapshot.replay().unwrap().to_json(),
        )
      }
    }
  }
  let input = {
    ..replay_input(),
    aggregation: @moon-usage.Aggregation::Counter(RestartAtZero),
    events: [event("b", 9, 100), event("r", 11, 2)],
  }
  assert_eq(
    @moon-usage.capture(input).unwrap().replay().unwrap().usage.reset_events,
    1,
  )
}

///|
test "snapshot large exact amount and escaped identity survive JSON parse" {
  let input = {
    ..replay_input(),
    input_revision: "批次\"\n",
    events: [event("x\"\\", 11, 1000000000)],
    plan: {
      ..plan(),
      base_minor: 1000000000,
      tiers: [{ up_to: None, rate: 1000000000, }],
    },
  }
  let restored = @moon-usage.Snapshot::from_string(
    @moon-usage.capture(input).unwrap().to_string(),
  ).unwrap()
  assert_eq(restored.replay().unwrap().quote.total_minor, 1000000001000000000L)
}

///|
test "snapshot parser rejects malformed JSON and repeated decoded object keys" {
  for
    text in [
      "{", "{\"schema\":1,\"schema\":2}", "{\"schema\":1,\"\\u0073chema\":2}",
    ] {
    assert_true(
      @moon-usage.Snapshot::from_string(text).unwrap_err() is InvalidJson(_),
    )
  }
}

///|
test "snapshot rejects rounded fractional tokens and inconsistent numeric representations" {
  let text = @moon-usage.capture(replay_input()).unwrap().to_string()
  for token in ["10.0000000000000000001", "1e1", "10.0"] {
    let altered = text.replace_all(old="\"start\":10", new="\"start\":" + token)
    assert_true(altered != text)
    assert_true(
      @moon-usage.Snapshot::from_string(altered).unwrap_err()
      is InvalidSnapshot(_),
    )
  }
  let saved = @moon-usage.capture(replay_input()).unwrap().to_json()
  object(object(object(saved)["bill"])["quote"])["quantity"] = Json::number(
    10.0,
    repr="999",
  )
  assert_eq(
    @moon-usage.Snapshot::from_json(saved).unwrap_err(),
    @moon-usage.ReplayError::BillMismatch,
  )
}

///|
test "snapshot rejects event and tier resource limits before computing" {
  let input = {
    ..replay_input(),
    events: Array::make(100001, event("x", 11, 1)),
  }
  assert_true(@moon-usage.capture(input).unwrap_err() is InvalidSnapshot(_))
  let input = {
    ..replay_input(),
    plan: { ..plan(), tiers: Array::make(4097, { up_to: None, rate: 1, }), },
  }
  assert_true(@moon-usage.capture(input).unwrap_err() is InvalidSnapshot(_))
}
