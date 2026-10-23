///|
fn request(id : String, account : String) -> @moon-usage.BillRequest {
  {
    id,
    account,
    meter: "m",
    start: 10,
    end: 20,
    aggregation: Sum,
    plan_revision: "price-1",
    plan: plan(),
  }
}

///|
test "batch bills isolate accounts and group totals deterministically by currency" {
  let events = [
    event("a", 11, 10),
    { ..event("b", 11, 20), account: "b", },
    { ..event("c", 11, 10), account: "c", },
  ]
  let usd = { ..request("usd", "c"), plan: { ..plan(), currency: "USD", }, }
  let result = @moon-usage.capture_batch(events, "events-1", [
    usd,
    request("first", "a"),
    { ..request("peak", "b"), aggregation: Peak, },
  ]).unwrap()
  assert_eq(result.bills.map(fn(b) { b.id }), ["usd", "first", "peak"])
  assert_eq(result.bills[1].snapshot.replay().unwrap().quote.total_minor, 35L)
  assert_eq(result.bills[2].snapshot.replay().unwrap().quote.total_minor, 55L)
  assert_eq(result.totals, [
    { currency: "CNY", total_minor: 90L, },
    { currency: "USD", total_minor: 35L, },
  ])
}

///|
test "batch refuses duplicate labels contexts and a failed request without partial results" {
  let events = [event("a", 11, 10)]
  assert_eq(
    @moon-usage.capture_batch(events, "v1", []).unwrap_err(),
    @moon-usage.BatchError::InvalidRequestCount,
  )
  assert_eq(
    @moon-usage.capture_batch(events, "v1", [
      request("same", "a"),
      request("same", "b"),
    ]).unwrap_err(),
    @moon-usage.BatchError::DuplicateRequest("same"),
  )
  assert_eq(
    @moon-usage.capture_batch(events, "v1", [
      request("first", "a"),
      request("again", "a"),
    ]).unwrap_err(),
    @moon-usage.BatchError::DuplicateContext("again"),
  )
  let invalid = {
    ..request("bad-plan", "b"),
    plan: { ..plan(), per_units: 0, },
  }
  guard @moon-usage.capture_batch(events, "v1", [request("good", "a"), invalid])
    is Err(CalculationFailed("bad-plan", CalculationFailed(InvalidPlan(_)))) else {
    abort("Expected named request failure")
  }
}

///|
test "batch refuses global event conflicts and currency sum overflow" {
  guard @moon-usage.capture_batch(
      [event("a", 11, 10), event("a", 11, 11)],
      "v1",
      [request("first", "a")],
    )
    is Err(
      CalculationFailed("first", CalculationFailed(DuplicateConflict("a")))
    ) else {
    abort("Expected full batch event validation")
  }
  let events : Array[@moon-usage.Event] = []
  let requests : Array[@moon-usage.BillRequest] = []
  for i in 0..<10 {
    let id = i.to_string()
    events.push({ ..event(id, 11, 1000000000), account: id, })
    requests.push({
      ..request(id, id),
      plan: {
        ..plan(),
        base_minor: 0,
        tiers: [{ up_to: None, rate: 1000000000, }],
      },
    })
  }
  assert_eq(
    @moon-usage.capture_batch(events, "v1", requests).unwrap_err(),
    @moon-usage.BatchError::TotalOverflow("CNY"),
  )
}
