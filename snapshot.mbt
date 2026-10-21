///|
/// Complete input for one reproducible calculation. Revisions are caller labels.
pub(all) struct BillInput {
  input_revision : String
  plan_revision : String
  events : Array[Event]
  account : String
  meter : String
  start : Int32
  end : Int32
  aggregation : Aggregation
  plan : Plan
}

///|
/// Stores a serialized copy so later mutations of input arrays cannot alter it.
pub struct Snapshot {
  document : String
}

///|
pub(all) enum ReplayError {
  InvalidSnapshot(String)
  InvalidJson(String)
  UnsupportedSchema(String)
  UnsupportedRules(String)
  CalculationFailed(UsageError)
  BillMismatch
} derive(Eq, Debug)

///|
pub extend ReplayError with Eq::{equal, not_equal}

///|
pub extend ReplayError with @debug.Debug::{to_repr}

///|
priv suberror SnapshotDecodeError {
  BadField(String)
}

///|
fn object_fields(
  value : Json,
  keys : Array[String],
  path : String,
) -> Map[String, Json] raise SnapshotDecodeError {
  guard value is Object(fields) else { raise BadField(path) }
  if fields.length() != keys.length() {
    raise BadField(path + ": unexpected or missing fields")
  }
  for key in keys {
    if fields.get(key) is None {
      raise BadField(path + "." + key)
    }
  }
  fields
}

///|
fn string_field(
  value : Json,
  path : String,
) -> String raise SnapshotDecodeError {
  guard value is String(s) else { raise BadField(path) }
  s
}

///|
fn integer_field(
  value : Json,
  path : String,
) -> Int32 raise SnapshotDecodeError {
  guard value is Number(n, repr~) else { raise BadField(path) }
  // Check before conversion: NaN, infinities, fractions and out-of-range values fail.
  if !(n >= 0.0 && n <= 2147483647.0) {
    raise BadField(path)
  }
  let integer = n.to_int()
  if integer.to_double() != n {
    raise BadField(path)
  }
  // Preserved JSON tokens must be plain integers, not rounded fractions/exponents.
  if repr is Some(text) && text != integer.to_string() {
    raise BadField(path + ": expected a plain nonnegative integer")
  }
  integer
}

///|
fn decode_input(value : Json) -> BillInput raise SnapshotDecodeError {
  let f = object_fields(
    value,
    [
      "input_revision", "plan_revision", "events", "account", "meter", "start", "end",
      "aggregation", "reset_policy", "plan",
    ],
    "input",
  )
  let input_revision = string_field(f["input_revision"], "input.input_revision")
  let plan_revision = string_field(f["plan_revision"], "input.plan_revision")
  if input_revision == "" || plan_revision == "" {
    raise BadField("input: empty revision")
  }
  guard f["events"] is Array(raw_events) else { raise BadField("input.events") }
  if raw_events.length() > 100000 {
    raise BadField("input.events: limit 100000")
  }
  let events : Array[Event] = []
  for i, value in raw_events {
    let path = "input.events[\{i}]"
    let e = object_fields(
      value,
      ["id", "account", "meter", "time", "value"],
      path,
    )
    events.push({
      id: string_field(e["id"], path + ".id"),
      account: string_field(e["account"], path + ".account"),
      meter: string_field(e["meter"], path + ".meter"),
      time: integer_field(e["time"], path + ".time"),
      value: integer_field(e["value"], path + ".value"),
    })
  }
  let aggregation = match string_field(f["aggregation"], "input.aggregation") {
    "sum" => Sum
    "peak" => Peak
    "last" => Last
    "counter" =>
      match string_field(f["reset_policy"], "input.reset_policy") {
        "reject_decrease" => Counter(RejectDecrease)
        "restart_at_zero" => Counter(RestartAtZero)
        _ => raise BadField("input.reset_policy")
      }
    _ => raise BadField("input.aggregation")
  }
  if !(aggregation is Counter(_)) && f["reset_policy"] != Json::null() {
    raise BadField("input.reset_policy: must be null for non-counter")
  }
  let p = object_fields(
    f["plan"],
    ["currency", "pricing", "rounding", "per_units", "base_minor", "tiers"],
    "input.plan",
  )
  let pricing = match string_field(p["pricing"], "input.plan.pricing") {
    "graduated" => Graduated
    "volume" => Volume
    _ => raise BadField("input.plan.pricing")
  }
  let rounding = match string_field(p["rounding"], "input.plan.rounding") {
    "down" => Down
    "up" => Up
    "half_even" => HalfEven
    _ => raise BadField("input.plan.rounding")
  }
  guard p["tiers"] is Array(raw_tiers) else {
    raise BadField("input.plan.tiers")
  }
  if raw_tiers.length() > 4096 {
    raise BadField("input.plan.tiers: limit 4096")
  }
  let tiers : Array[Tier] = []
  for i, value in raw_tiers {
    let path = "input.plan.tiers[\{i}]"
    let t = object_fields(value, ["up_to", "rate"], path)
    let up_to = if t["up_to"] == Json::null() {
      None
    } else {
      Some(integer_field(t["up_to"], path + ".up_to"))
    }
    tiers.push({ up_to, rate: integer_field(t["rate"], path + ".rate"), })
  }
  {
    input_revision,
    plan_revision,
    events,
    account: string_field(f["account"], "input.account"),
    meter: string_field(f["meter"], "input.meter"),
    start: integer_field(f["start"], "input.start"),
    end: integer_field(f["end"], "input.end"),
    aggregation,
    plan: {
      currency: string_field(p["currency"], "input.plan.currency"),
      pricing,
      rounding,
      tiers,
      per_units: integer_field(p["per_units"], "input.plan.per_units"),
      base_minor: integer_field(p["base_minor"], "input.plan.base_minor"),
    },
  }
}

///|
pub fn BillInput::from_json(value : Json) -> Result[BillInput, ReplayError] {
  Ok(decode_input(value)) catch {
    BadField(path) => Err(InvalidSnapshot(path))
  }
}

///|
pub fn BillInput::to_json(self : BillInput) -> Json {
  let (aggregation, policy) = match self.aggregation {
    Sum => ("sum", Json::null())
    Peak => ("peak", Json::null())
    Last => ("last", Json::null())
    Counter(RejectDecrease) => ("counter", Json("reject_decrease"))
    Counter(RestartAtZero) => ("counter", Json("restart_at_zero"))
  }
  Json({
    "input_revision": Json(self.input_revision),
    "plan_revision": Json(self.plan_revision),
    "account": Json(self.account),
    "meter": Json(self.meter),
    "start": Json(self.start),
    "end": Json(self.end),
    "aggregation": Json(aggregation),
    "reset_policy": policy,
    "events": Json(
      self.events.map(fn(e) {
        Json({
          "id": Json(e.id),
          "account": Json(e.account),
          "meter": Json(e.meter),
          "time": Json(e.time),
          "value": Json(e.value),
        })
      }),
    ),
    "plan": Json({
      "currency": Json(self.plan.currency),
      "pricing": Json(
        match self.plan.pricing {
          Graduated => "graduated"
          Volume => "volume"
        },
      ),
      "rounding": Json(
        match self.plan.rounding {
          Down => "down"
          Up => "up"
          HalfEven => "half_even"
        },
      ),
      "per_units": Json(self.plan.per_units),
      "base_minor": Json(self.plan.base_minor),
      "tiers": Json(
        self.plan.tiers.map(fn(t) {
          Json({
            "up_to": match t.up_to {
              Some(n) => Json(n)
              None => Json::null()
            },
            "rate": Json(t.rate),
          })
        }),
      ),
    }),
  })
}

///|
pub fn capture(input : BillInput) -> Result[Snapshot, ReplayError] {
  // Apply the same schema/resource validation to typed and JSON callers.
  match BillInput::from_json(input.to_json()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let result = match
    bill(
      input.events,
      input.account,
      input.meter,
      input.start,
      input.end,
      input.aggregation,
      input.plan,
    ) {
    Err(e) => return Err(CalculationFailed(e))
    Ok(b) => b
  }
  freeze_snapshot(input, result)
}

///|
fn freeze_snapshot(
  input : BillInput,
  result : Bill,
) -> Result[Snapshot, ReplayError] {
  let document = Json({
    "schema": Json("moon-usage.replay.v1"),
    "rules": Json("moon-usage.rules.v1"),
    "input": input.to_json(),
    "bill": result.to_json(),
  }).stringify()
  if document.length() > 16777216 {
    return Err(InvalidSnapshot("text: limit 16Mi code units"))
  }
  Ok({ document, })
}

///|
fn valid_bill_numbers(value : Json) -> Bool {
  match value {
    Number(_, ..) =>
      try {
        ignore(integer_field(value, "bill"))
        true
      } catch {
        BadField(_) => false
      }
    Array(values) => values.iter().all(valid_bill_numbers)
    Object(fields) => fields.values().all(valid_bill_numbers)
    _ => true
  }
}

///|
fn verify_document(value : Json) -> Result[(BillInput, Bill), ReplayError] {
  let fields = object_fields(
    value,
    ["schema", "rules", "input", "bill"],
    "snapshot",
  ) catch {
    BadField(path) => return Err(InvalidSnapshot(path))
  }
  let schema = string_field(fields["schema"], "snapshot.schema") catch {
    BadField(path) => return Err(InvalidSnapshot(path))
  }
  if schema != "moon-usage.replay.v1" {
    return Err(UnsupportedSchema(schema))
  }
  let rules = string_field(fields["rules"], "snapshot.rules") catch {
    BadField(path) => return Err(InvalidSnapshot(path))
  }
  if rules != "moon-usage.rules.v1" {
    return Err(UnsupportedRules(rules))
  }
  let input = match BillInput::from_json(fields["input"]) {
    Ok(i) => i
    Err(e) => return Err(e)
  }
  let result = match
    bill(
      input.events,
      input.account,
      input.meter,
      input.start,
      input.end,
      input.aggregation,
      input.plan,
    ) {
    Ok(b) => b
    Err(e) => return Err(CalculationFailed(e))
  }
  if !valid_bill_numbers(fields["bill"]) || result.to_json() != fields["bill"] {
    return Err(BillMismatch)
  }
  Ok((input, result))
}

///|
pub fn Snapshot::from_json(value : Json) -> Result[Snapshot, ReplayError] {
  match verify_document(value) {
    Err(e) => Err(e)
    // Serialize decoded values and computed results, never caller-provided number reprs.
    Ok((input, result)) => freeze_snapshot(input, result)
  }
}

///|
pub fn Snapshot::from_string(text : String) -> Result[Snapshot, ReplayError] {
  if text.length() > 16777216 {
    return Err(InvalidSnapshot("text: limit 16Mi code units"))
  }
  let value = @json.parse(
    text,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
    max_nesting_depth=64,
  ) catch {
    e => return Err(InvalidJson(e.to_string()))
  }
  Snapshot::from_json(value)
}

///|
pub fn Snapshot::to_json(self : Snapshot) -> Json {
  @json.parse(self.document) catch {
    _ => abort("Invalid internal snapshot")
  }
}

///|
/// Return the complete frozen record as JSON text.
pub fn Snapshot::to_string(self : Snapshot) -> String {
  self.document
}

///|
/// Recompute and compare the entire bill. This is consistency checking, not authentication.
pub fn Snapshot::replay(self : Snapshot) -> Result[Bill, ReplayError] {
  match verify_document(self.to_json()) {
    Ok((_, result)) => Ok(result)
    Err(e) => Err(e)
  }
}
