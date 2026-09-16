# frozen_string_literal: true

require_relative "../test_helper"
require "bigdecimal"
require "date"

# How a Ruby value reaches the server as a bound parameter.
#
# The server substitutes these at value positions its grammar has already fixed, so
# the only question here is whether the value that arrives is the value that was
# passed — which is why every case checks the encoded form rather than only that
# nothing was raised.
class ParamsTest < Minitest::Test
  def test_scalars_pass_through_unchanged
    assert_nil TriCoreDB::Params.encode(nil)
    assert_equal true, TriCoreDB::Params.encode(true)
    assert_equal false, TriCoreDB::Params.encode(false)
    assert_equal 42, TriCoreDB::Params.encode(42)
    assert_equal(-7, TriCoreDB::Params.encode(-7))
    assert_equal "O'Hara", TriCoreDB::Params.encode("O'Hara"), "a quote is data, never syntax"
  end

  def test_wide_integers_stay_exact
    big = 170_141_183_460_469_231_731_687_303_715_884_105_727
    assert_equal big, TriCoreDB::Params.encode(big)
    assert_equal 18_446_744_073_709_551_615, TriCoreDB::Params.encode(18_446_744_073_709_551_615)
  end

  def test_floats_are_numbers_and_non_finite_ones_are_refused
    assert_in_delta(-0.125, TriCoreDB::Params.encode(-0.125))
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
      error = assert_raises(TriCoreDB::ParameterError) { TriCoreDB::Params.encode(value, 3) }
      assert_match(/no SQL value/, error.message)
    end
  end

  def test_binary_becomes_lowercase_hex_a_blob_column_parses
    assert_equal "0x00abff10", TriCoreDB::Params.encode(TriCoreDB::Binary.new([0x00, 0xab, 0xff, 0x10]))
    assert_equal "0x", TriCoreDB::Params.encode(TriCoreDB::Binary.new(""))
    # A binary-encoded String is bytes too, whatever it happens to contain.
    assert_equal "0xc328", TriCoreDB::Params.encode("\xC3\x28".b)
    # …and the helper is the same thing spelled out.
    assert_equal TriCoreDB::Binary.new("hi"), TriCoreDB.binary("hi")
  end

  def test_text_must_be_valid_utf8
    assert_equal "héllo", TriCoreDB::Params.encode("héllo")
    invalid = +"a\xC3b"
    invalid.force_encoding(Encoding::UTF_8)
    assert_raises(TriCoreDB::ParameterError) { TriCoreDB::Params.encode(invalid) }
  end

  def test_a_decimal_goes_out_as_plain_digits
    # A float would lose the digits a BigDecimal exists to keep, and an exponent
    # would be read as a DOUBLE.
    assert_equal "10.5", TriCoreDB::Params.encode(BigDecimal("10.50"))
    assert_equal "1500.0", TriCoreDB::Params.encode(BigDecimal("1.5E+3"))
    refute_match(/[eE]/, TriCoreDB::Params.encode(BigDecimal("1e-20")))
  end

  def test_times_and_dates_go_out_as_text
    encoded = TriCoreDB::Params.encode(Time.utc(2026, 9, 16, 12, 30, 0))
    assert_kind_of String, encoded
    assert_match(/2026-09-16/, encoded)
    assert_equal "2026-09-16", TriCoreDB::Params.encode(Date.new(2026, 9, 16))
  end

  def test_a_value_with_no_scalar_form_is_refused_rather_than_stringified
    error = assert_raises(TriCoreDB::ParameterError) { TriCoreDB::Params.encode([1, 2, 3], 2) }
    assert_match(/parameter #2/, error.message)
    assert_raises(TriCoreDB::ParameterError) { TriCoreDB::Params.encode({ "a" => 1 }) }
    assert_raises(TriCoreDB::ParameterError) { TriCoreDB::Params.encode(:symbol) }
  end

  def test_a_parameter_list_keeps_its_order
    assert_equal [1, "ada", nil, "0x01"],
                 TriCoreDB::Params.encode_all([1, "ada", nil, TriCoreDB::Binary.new([1])])
    assert_raises(ArgumentError) { TriCoreDB::Params.encode_all("not an array") }
  end
end
