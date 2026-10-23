///|
fn main {
  let plan : @usage.Plan = {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 1,
    base_minor: 5,
    tiers: [{ up_to: Some(10), rate: 3, }, { up_to: None, rate: 2, }],
  }
  let events : Array[@usage.Event] = [
    { id: "request-a", account: "a", meter: "requests", time: 11, value: 10, },
    { id: "request-b", account: "b", meter: "requests", time: 12, value: 20, },
  ]
  let requests : Array[@usage.BillRequest] = ["a", "b"].map(fn(account) {
    {
      id: account,
      account,
      meter: "requests",
      start: 10,
      end: 20,
      aggregation: Sum,
      plan_revision: "price-1",
      plan,
    }
  })
  let result = @usage.capture_batch(events, "events-1", requests).unwrap()
  for bill in result.bills {
    let amount = bill.snapshot.replay().unwrap().quote.total_minor
    println("\{bill.id}: \{amount}")
  }
  for total in result.totals {
    println("\{total.currency} total: \{total.total_minor}")
  }
}
