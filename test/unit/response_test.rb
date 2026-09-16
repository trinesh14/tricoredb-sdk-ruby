# frozen_string_literal: true

require_relative "../test_helper"

# What the driver reads out of a RESPONSE frame.
class ResponseTest < Minitest::Test
  def test_a_successful_response_reports_its_diagnostics
    response = TriCoreDB::Response.new(
      "request_id" => "r1",
      "status" => "ok",
      "data" => { "Message" => "done" },
      "diagnostics" => { "route" => "local", "elapsed_ms" => 4, "warnings" => ["shard 2 was unreachable"] }
    )

    assert response.ok?
    assert_equal "r1", response.request_id
    assert_equal "Message", response.kind
    assert_equal ["shard 2 was unreachable"], response.warnings,
                 "a partly applied broadcast warns while the status is still ok"
    refute response.redirect?
  end

  def test_the_data_arms_are_addressable
    response = TriCoreDB::Response.new("status" => "ok", "data" => { "Json" => { "rows_affected" => 3 } })

    assert response.arm?("Json")
    refute response.arm?("Rows")
    assert_equal 3, response.rows_affected
    assert_nil TriCoreDB::Response.new("status" => "ok", "data" => "Empty").rows_affected
  end

  def test_a_not_leader_refusal_is_typed_and_names_the_leader
    response = TriCoreDB::Response.new(
      "status" => "error",
      "data" => { "Message" => "not the raft leader" },
      "diagnostics" => { "error_code" => "not_leader", "leader_hint" => "10.9.9.7:8427" }
    )

    assert response.redirect?, "the code decides this, never the message text"
    assert_equal "10.9.9.7:8427", response.leader_hint

    error = response.to_error
    assert_kind_of TriCoreDB::ServerError, error
    assert_equal "not_leader", error.code
    assert_equal "10.9.9.7:8427", error.leader_hint
    assert_match(/does not follow the hint/, error.message)
  end

  def test_mid_election_there_is_a_code_but_no_address
    response = TriCoreDB::Response.new(
      "status" => "error",
      "data" => { "Message" => "not the raft leader" },
      "diagnostics" => { "error_code" => "not_leader" }
    )

    assert response.redirect?
    assert_nil response.leader_hint,
               "an absent hint means the destination is unknown, not that there was no redirect"
    assert_match(/Wait and try again/, response.to_error.message)
  end

  def test_an_open_transaction_is_reported_as_over_after_a_redirect
    response = TriCoreDB::Response.new(
      "status" => "error",
      "data" => { "Message" => "not the raft leader" },
      "diagnostics" => { "error_code" => "not_leader", "leader_hint" => "10.0.0.2:8427" }
    )

    assert_match(/session transaction is over/, response.to_error(true).message)
    refute_match(/session transaction is over/, response.to_error(false).message)
  end

  def test_an_ordinary_failure_is_not_read_as_a_redirect
    response = TriCoreDB::Response.new(
      "status" => "error",
      "data" => { "Message" => "syntax error" },
      "diagnostics" => { "error_code" => "request.invalid" }
    )

    refute response.redirect?
    error = response.to_error
    assert_equal "request.invalid", error.code
    assert_match(/syntax error/, error.message)
  end

  def test_rows_read_by_position_and_by_name
    rows = TriCoreDB::Rows.new(%w[id name], [%w[1 ada], %w[2 grace]])

    assert_equal 2, rows.size
    assert_equal %w[1 ada], rows.first
    assert_equal({ "id" => "1", "name" => "ada" }, rows.to_hashes.first)
    assert_equal %w[ada grace], rows.map { |row| row[1] }
  end

  def test_a_stream_entry_reads_back_as_text
    entry = TriCoreDB::StreamEntry.new("1-0", [%w[msg hi]])

    assert_equal "1-0", entry.id
    assert_equal({ "msg" => "hi" }, entry.text)
  end
end
