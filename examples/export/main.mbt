///|
fn main {
  let events : Array[@usage.Event] = [
    { id: "baseline", account: "demo", meter: "device", time: 9, value: 1000, },
    { id: "reading", account: "demo", meter: "device", time: 11, value: 1030, },
    { id: "reset", account: "demo", meter: "device", time: 12, value: 4, },
  ]
  let plan : @usage.Plan = {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 1,
    base_minor: 0,
    tiers: [{ up_to: None, rate: 8, }],
  }
  let result = @usage.bill(
    events,
    "demo",
    "device",
    10,
    20,
    Counter(RestartAtZero),
    plan,
  )
  match result {
    Ok(bill) => println(bill.to_json().stringify(indent=2))
    Err(error) => abort(error.to_repr().to_string())
  }
}
