# frozen_string_literal: true

module TriCoreDB
  # Builders for the server's `DocumentFilter`, externally tagged.
  #
  # @example
  #   TriCoreDB::Filter.all_of(TriCoreDB::Filter.eq("city", "Pune"), TriCoreDB::Filter.gt("visits", 4))
  module Filter
    module_function

    # @return [String] matches every document
    def all
      "All"
    end

    %w[Eq Ne Gt Gte Lt Lte Contains].each do |variant|
      define_method(variant.downcase) do |field, value|
        { variant => { "field" => field.to_s, "value" => value } }
      end
    end

    # `field` equals any of `values`.
    # @return [Hash]
    def in_list(field, values)
      { "In" => { "field" => field.to_s, "values" => Array(values) } }
    end

    # Every sub-filter must match.
    # @return [Hash]
    def all_of(*filters)
      { "And" => filters.flatten }
    end

    class << self
      alias_method :and, :all_of
    end
  end

  # Builders for `GroupAccumulator`.
  module Acc
    module_function

    %w[Sum Avg Min Max].each do |variant|
      define_method(variant.downcase) do |output, field|
        { "output" => output.to_s, "op" => { variant => field.to_s } }
      end
    end

    # Counts documents in the group.
    # @return [Hash]
    def count(output)
      { "output" => output.to_s, "op" => "Count" }
    end
  end

  # Builders for `AggregateStage`. Stages apply strictly in order.
  module Stage
    module_function

    # @return [Hash]
    def match(filter)
      { "Match" => filter }
    end

    # @param by [Hash] from {by_field} or {by_constant}
    # @param accumulators [Array<Hash>] from {Acc}
    # @return [Hash]
    def group(by, accumulators = [])
      { "Group" => { "by" => by, "accumulators" => accumulators } }
    end

    # @param keys [Array<Array(String, Boolean)>, Array<Hash>] `[field, descending]` pairs or `{field:, descending:}`
    # @return [Hash]
    def sort(*keys)
      list = keys.flatten(1).map do |k|
        if k.is_a?(Hash)
          { "field" => (k[:field] || k["field"]).to_s, "descending" => !!(k[:descending] || k["descending"]) }
        elsif k.is_a?(Array)
          { "field" => k[0].to_s, "descending" => !!k[1] }
        else
          { "field" => k.to_s, "descending" => false }
        end
      end
      { "Sort" => list }
    end

    def skip(n)
      { "Skip" => Integer(n) }
    end

    def limit(n)
      { "Limit" => Integer(n) }
    end

    def project(fields, include: true)
      { "Project" => { "fields" => Array(fields).map(&:to_s), "include" => include ? true : false } }
    end

    # Collapse the stream to one document `{field => n}`.
    def count(field)
      { "Count" => { "field" => field.to_s } }
    end

    def by_field(field)
      { "Field" => field.to_s }
    end

    def by_constant(value)
      { "Constant" => value }
    end
  end

  # Builders for `LlmSource`.
  module LlmSource
    module_function

    # @return [Hash]
    def sql(query)
      { "Sql" => { "query" => query.to_s } }
    end

    # @return [Hash]
    def documents(collection, filter: Filter.all, limit: nil)
      { "DocumentFind" => { "collection" => collection.to_s, "filter" => filter, "limit" => limit } }
    end

    # Accepts a built source, or `{sql:}` / `{collection:, filter:, limit:}`.
    # @return [Hash]
    def coerce(src)
      return src if src.is_a?(Hash) && (src.key?("Sql") || src.key?("DocumentFind"))
      raise ArgumentError, "an LLM source must be a Hash" unless src.is_a?(Hash)

      sql_text = src[:sql] || src["sql"]
      return sql(sql_text) if sql_text

      coll = src[:collection] || src["collection"]
      raise ArgumentError, "an LLM source needs :sql or :collection" unless coll

      documents(coll, filter: src[:filter] || src["filter"] || Filter.all, limit: src[:limit] || src["limit"])
    end
  end
end
