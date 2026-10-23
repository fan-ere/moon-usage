///|
test "input text roundtrip retains full events and pricing" {
  let input = replay_input()
  let decoded = @moon-usage.BillInput::from_string(input.to_json().stringify()).unwrap()
  assert_eq(decoded.to_json(), input.to_json())
  assert_eq(
    @moon-usage.capture(decoded).unwrap().replay().unwrap().quote.total_minor,
    35L,
  )
}

///|
test "input text rejects duplicate keys fractional drift and exponent tokens" {
  for text in ["{\"account\":\"a\",\"account\":\"b\"}", "{not json}"] {
    guard @moon-usage.BillInput::from_string(text) is Err(InvalidJson(_)) else {
      abort("Expected JSON error")
    }
  }
  for number in ["10.0000000000000001", "1e1", "-0"] {
    let text = replay_input()
      .to_json()
      .stringify()
      .replace(old="\"start\":10", new="\"start\":" + number)
    guard @moon-usage.BillInput::from_string(text) is Err(InvalidSnapshot(_)) else {
      abort("Expected integer token rejection")
    }
  }
}

///|
test "input decoding does not bypass billing semantics" {
  let input = replay_input()
  let value = input.to_json()
  object(value)["end"] = Json(5)
  let decoded = @moon-usage.BillInput::from_string(value.stringify()).unwrap()
  assert_eq(
    @moon-usage.capture(decoded).unwrap_err(),
    @moon-usage.ReplayError::CalculationFailed(InvalidPeriod),
  )
  let mut text = "0"
  for _ in 0..<70 {
    text = "[" + text + "]"
  }
  guard @moon-usage.BillInput::from_string(text) is Err(InvalidJson(_)) else {
    abort("Expected nesting limit rejection")
  }
}
