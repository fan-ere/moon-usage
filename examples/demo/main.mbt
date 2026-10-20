///|
fn e(id : String, meter : String, time : Int, value : Int) -> @usage.Event {
  { id, account: "demo", meter, time, value, }
}

///|
fn show(
  title : String,
  result : Result[@usage.Bill, @usage.UsageError],
) -> Unit {
  match result {
    Err(error) => println(title + " ERROR " + error.to_repr().to_string())
    Ok(bill) => {
      println(
        "\{title}: units=\{bill.usage.quantity} total_minor=\{bill.quote.total_minor} currency=\{bill.quote.currency}",
      )
      println(
        "  events=\{bill.usage.accepted_events} duplicates=\{bill.usage.duplicate_events} resets=\{bill.usage.reset_events}",
      )
      for line in bill.quote.lines {
        println(
          "  tier=\{line.tier} units=\{line.quantity} rate=\{line.rate} exact=\{line.numerator}/\{bill.quote.denominator}",
        )
      }
    }
  }
}

///|
fn main {
  let api_plan : @usage.Plan = {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 1000,
    base_minor: 100,
    tiers: [
      { up_to: Some(1000), rate: 0, },
      { up_to: Some(10000), rate: 300, },
      { up_to: None, rate: 200, },
    ],
  }
  let api = [
    e("api-1", "requests", 11, 6000),
    e("api-2", "requests", 15, 6500),
    e("api-1", "requests", 11, 6000),
  ]
  show(
    "API graduated",
    @usage.bill(api, "demo", "requests", 10, 20, Sum, api_plan),
  )
  let storage_plan : @usage.Plan = {
    currency: "CNY",
    pricing: Volume,
    rounding: Up,
    per_units: 1,
    base_minor: 0,
    tiers: [{ up_to: Some(100), rate: 5, }, { up_to: None, rate: 3, }],
  }
  show(
    "Storage peak",
    @usage.bill(
      [
        e("s1", "storage", 11, 80),
        e("s2", "storage", 12, 120),
        e("s3", "storage", 13, 90),
      ],
      "demo",
      "storage",
      10,
      20,
      Peak,
      storage_plan,
    ),
  )
  let device_plan : @usage.Plan = {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 1,
    base_minor: 0,
    tiers: [{ up_to: None, rate: 8, }],
  }
  let readings = [
    e("baseline", "device", 9, 1000),
    e("d1", "device", 11, 1030),
    e("reset", "device", 12, 4),
    e("d2", "device", 14, 12),
  ]
  show(
    "Device counter",
    @usage.bill(
      readings,
      "demo",
      "device",
      10,
      20,
      Counter(RestartAtZero),
      device_plan,
    ),
  )
  show(
    "Counter strict",
    @usage.bill(
      readings,
      "demo",
      "device",
      10,
      20,
      Counter(RejectDecrease),
      device_plan,
    ),
  )
  show(
    "Conflicting retry",
    @usage.bill(
      [e("same", "requests", 11, 1), e("same", "requests", 11, 2)],
      "demo",
      "requests",
      10,
      20,
      Sum,
      api_plan,
    ),
  )
}
