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

  # What a cache call does to a key's expiry.
  module CacheExpiry
    module_function

    # Leave the expiry as it is.
    def keep
      "Keep"
    end

    # Remove the expiry, which is what a plain set does.
    def clear
      "Clear"
    end

    # Expire `ttl_ms` milliseconds from now.
    # @return [Hash]
    def set(ttl_ms)
      { "Set" => { "ttl_ms" => Integer(ttl_ms) } }
    end
  end

  # One end of a sorted-set score range.
  #
  # JSON has no infinity, so an unbounded end is sent as the largest finite Float,
  # which no finite score lies beyond.
  module ScoreBound
    module_function

    # A bound that includes members scoring exactly `value`.
    # @return [Hash]
    def inclusive(value)
      bound(value, false)
    end

    # A bound that leaves out members scoring exactly `value`.
    # @return [Hash]
    def exclusive(value)
      bound(value, true)
    end

    # No lower limit.
    def lowest
      bound(-Float::INFINITY, false)
    end

    # No upper limit.
    def highest
      bound(Float::INFINITY, false)
    end

    # @api private
    def bound(value, exclusive)
      number = Float(value)
      raise ArgumentError, "a score bound must not be NaN" if number.nan?

      number = number.positive? ? Float::MAX : -Float::MAX if number.infinite?
      { "value" => number, "exclusive" => exclusive }
    end
  end

  # Builders for the cache operations a pipeline, a transaction or a script runs.
  # Each is the operation exactly as it would be sent alone.
  #
  # @example
  #   db.cache_pipeline([TriCoreDB::CacheOp.set("sessions", "abc", "ada"), TriCoreDB::CacheOp.get("sessions", "abc")])
  module CacheOp
    module_function

    # A liveness check.
    def ping
      "Ping"
    end

    # Any cache operation by its server name, with its fields as the server names
    # them. Byte fields are Arrays of byte values.
    # @return [Hash]
    def raw(variant, body)
      { variant.to_s => body }
    end

    # @param value [String, Array<Integer>]
    def set(namespace, key, value, ttl_ms: nil)
      raw("Set", "namespace" => namespace.to_s, "key" => key.to_s,
                 "value" => value.is_a?(String) ? value.bytes : value, "ttl_ms" => ttl_ms)
    end

    def get(namespace, key)
      raw("Get", "namespace" => namespace.to_s, "key" => key.to_s)
    end

    def delete(namespace, key)
      raw("Delete", "namespace" => namespace.to_s, "key" => key.to_s)
    end

    def exists(namespace, key)
      raw("Exists", "namespace" => namespace.to_s, "key" => key.to_s)
    end

    def incr(namespace, key, by = 1)
      raw("Incr", "namespace" => namespace.to_s, "key" => key.to_s, "by" => Integer(by))
    end

    def expire(namespace, key, ttl_ms)
      raw("Expire", "namespace" => namespace.to_s, "key" => key.to_s, "ttl_ms" => Integer(ttl_ms))
    end
  end

  # Builders for the operations of {Client#doc_bulk_write}.
  module BulkOp
    module_function

    # Insert a document, under `id` when one is given.
    # @return [Hash]
    def insert(document, id: nil)
      { "Insert" => { "id" => id, "document" => document } }
    end

    # Set or increment fields on one document. `expected_version` applies it only
    # if the document's `_version` is still that.
    # @return [Hash]
    def update_one(id, set: nil, inc: nil, upsert: false, expected_version: nil)
      update = {}
      update["set"] = set if set && !set.empty?
      update["inc"] = inc if inc && !inc.empty?
      { "UpdateOne" => { "id" => id, "update" => update, "upsert" => upsert ? true : false,
                         "expected_version" => expected_version } }
    end

    # Swap a document's whole body for `document`.
    # @return [Hash]
    def replace(id, document, upsert: false, expected_version: nil)
      { "Replace" => { "id" => id, "document" => document, "upsert" => upsert ? true : false,
                       "expected_version" => expected_version } }
    end

    # Delete one document by id.
    # @return [Hash]
    def delete(id, expected_version: nil)
      { "Delete" => { "id" => id, "expected_version" => expected_version } }
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
