# frozen_string_literal: true

require_relative "../test_helper"

# The filter, accumulator, stage and LLM-source builders.
#
# These exist so a caller never writes the request JSON by hand, which means the
# shape they produce *is* the contract with the server — so each case asserts the
# shape, not merely that a Hash came back.
class BuildersTest < Minitest::Test
  def test_filters_are_externally_tagged
    assert_equal "All", TriCoreDB::Filter.all
    assert_equal({ "Eq" => { "field" => "city", "value" => "Pune" } }, TriCoreDB::Filter.eq("city", "Pune"))
    assert_equal({ "Gt" => { "field" => "price", "value" => 10 } }, TriCoreDB::Filter.gt("price", 10))
    assert_equal({ "Lte" => { "field" => "age", "value" => 40 } }, TriCoreDB::Filter.lte(:age, 40))
    assert_equal({ "Contains" => { "field" => "tags", "value" => "db" } }, TriCoreDB::Filter.contains("tags", "db"))
  end

  def test_in_and_and_nest_their_children_in_order
    assert_equal({ "In" => { "field" => "id", "values" => %w[a b] } }, TriCoreDB::Filter.in_list("id", %w[a b]))

    combined = TriCoreDB::Filter.all_of(TriCoreDB::Filter.eq("city", "Pune"), TriCoreDB::Filter.gt("visits", 4))
    assert_equal %w[Eq Gt], combined["And"].map { |f| f.keys.first }
    assert_equal combined, TriCoreDB::Filter.and(TriCoreDB::Filter.eq("city", "Pune"), TriCoreDB::Filter.gt("visits", 4))
  end

  def test_accumulators_name_their_output_and_operation
    assert_equal({ "output" => "total", "op" => { "Sum" => "amount" } }, TriCoreDB::Acc.sum("total", "amount"))
    assert_equal({ "output" => "average", "op" => { "Avg" => "amount" } }, TriCoreDB::Acc.avg("average", "amount"))
    # Count takes no field, because it counts documents rather than values.
    assert_equal({ "output" => "n", "op" => "Count" }, TriCoreDB::Acc.count("n"))
  end

  def test_pipeline_stages_keep_the_servers_own_names
    assert_equal({ "Match" => "All" }, TriCoreDB::Stage.match(TriCoreDB::Filter.all))
    assert_equal({ "Skip" => 2 }, TriCoreDB::Stage.skip(2))
    assert_equal({ "Limit" => 5 }, TriCoreDB::Stage.limit(5))
    assert_equal({ "Count" => { "field" => "n" } }, TriCoreDB::Stage.count("n"))
    assert_equal({ "Project" => { "fields" => %w[a b], "include" => true } }, TriCoreDB::Stage.project(%w[a b]))
    assert_equal({ "Project" => { "fields" => ["a"], "include" => false } },
                 TriCoreDB::Stage.project("a", include: false))
  end

  def test_a_group_stage_carries_its_key_and_accumulators
    stage = TriCoreDB::Stage.group(TriCoreDB::Stage.by_field("customer"), [TriCoreDB::Acc.sum("total", "amount")])

    assert_equal({ "Field" => "customer" }, stage["Group"]["by"])
    assert_equal "total", stage["Group"]["accumulators"].first["output"]
    assert_equal({ "Constant" => "all" }, TriCoreDB::Stage.by_constant("all"))
  end

  def test_sort_keys_accept_three_spellings_and_mean_the_same_thing
    expected = { "Sort" => [{ "field" => "total", "descending" => true }] }

    # A `[field, descending]` pair goes inside an array: the builder flattens one
    # level, so a bare pair would read as two separate keys.
    assert_equal expected, TriCoreDB::Stage.sort([["total", true]])
    assert_equal expected, TriCoreDB::Stage.sort({ field: "total", descending: true })
    assert_equal({ "Sort" => [{ "field" => "name", "descending" => false }] }, TriCoreDB::Stage.sort("name"))
    assert_equal({ "Sort" => [{ "field" => "a", "descending" => false },
                              { "field" => "b", "descending" => true }] },
                 TriCoreDB::Stage.sort([["a", false], ["b", true]]))
  end

  def test_llm_sources_are_built_or_coerced
    assert_equal({ "Sql" => { "query" => "SELECT 1" } }, TriCoreDB::LlmSource.sql("SELECT 1"))

    docs = TriCoreDB::LlmSource.documents("products", limit: 10)
    assert_equal "products", docs["DocumentFind"]["collection"]
    assert_equal "All", docs["DocumentFind"]["filter"]
    assert_equal 10, docs["DocumentFind"]["limit"]

    # A built source passes through, and a plain Hash is accepted as shorthand.
    assert_equal docs, TriCoreDB::LlmSource.coerce(docs)
    assert_equal({ "Sql" => { "query" => "SELECT 2" } }, TriCoreDB::LlmSource.coerce(sql: "SELECT 2"))
    assert_raises(ArgumentError) { TriCoreDB::LlmSource.coerce("SELECT 3") }
  end
end
