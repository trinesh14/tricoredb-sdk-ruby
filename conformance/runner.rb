# frozen_string_literal: true

# Conformance runner for the tricoredb gem.
#
#   ruby -Ilib conformance/runner.rb <host> <port> <user> <secret> < scenario.json
#
# Maps each canonical action to the public method a user would call and copies
# the typed result into canonical JSON, one object per step on stdout. It makes
# no assertions and never computes or defaults a value.

require "json"
require "tricoredb"

$stdout.sync = true

module ConformanceRunner
  F = TriCoreDB::Filter
  S = TriCoreDB::Stage
  A = TriCoreDB::Acc

  module_function

  def filter(spec)
    case spec["op"]
    when "all" then F.all
    when "eq" then F.eq(spec["field"], spec["value"])
    when "gt" then F.gt(spec["field"], spec["value"])
    when "contains" then F.contains(spec["field"], spec["value"])
    when "and" then F.all_of(*spec["filters"].map { |f| filter(f) })
    else raise ArgumentError, "unsupported filter op in the scenario: #{spec['op']}"
    end
  end

  def accumulator(acc)
    case acc["op"]
    when "sum" then A.sum(acc["output"], acc["field"])
    when "count" then A.count(acc["output"])
    else raise ArgumentError, "unsupported accumulator: #{acc['op']}"
    end
  end

  def stage(spec)
    case spec["stage"]
    when "match" then S.match(filter(spec["filter"]))
    when "group" then S.group(S.by_field(spec["by"]["field"]), spec["accumulators"].map { |a| accumulator(a) })
    when "sort" then S.sort(spec["keys"].map { |k| [k["field"], k["descending"]] })
    when "count" then S.count(spec["field"])
    else raise ArgumentError, "unsupported aggregate stage: #{spec['stage']}"
    end
  end

  def text(bytes)
    bytes.dup.force_encoding(Encoding::UTF_8)
  end

  def utf8_bytes(str)
    str.to_s.b
  end

  def value(v)
    v.nil? ? { "found" => false } : { "found" => true, "value" => text(v) }
  end

  def pairs(list)
    (list || []).map { |f, v| [utf8_bytes(f), utf8_bytes(v)] }
  end

  def entry(e)
    { "id" => e.id, "fields" => e.fields.map { |f, v| [text(f), text(v)] } }
  end

  def found(obj, *fields)
    return { "found" => false } if obj.nil?

    fields.each_with_object({ "found" => true }) { |f, h| h[f] = obj[f] }
  end

  ACTIONS = {
    "doc.createCollection" => ->(db, a, _) { db.doc_create_collection(a["collection"]); {} },
    "doc.dropCollection" => ->(db, a, _) { db.doc_drop_collection(a["collection"]); {} },
    "doc.listCollections" => ->(db, _a, _) { { "names" => db.doc_list_collections } },
    "doc.insert" => ->(db, a, _) { { "id" => db.doc_insert(a["collection"], a["document"], id: a["id"]) } },
    "doc.get" => lambda { |db, a, _|
      doc = db.doc_get(a["collection"], a["id"])
      doc.nil? ? { "found" => false } : { "found" => true, "doc" => doc }
    },
    "doc.find" => ->(db, a, _) { { "docs" => db.doc_find(a["collection"], filter(a["filter"]), limit: a["limit"]) } },
    "doc.update" => ->(db, a, _) { db.doc_update(a["collection"], a["id"], a["set"]); {} },
    "doc.updateOne" => lambda { |db, a, _|
      db.doc_update_one(a["collection"], a["id"], set: a["set"], inc: a["inc"], upsert: a["upsert"] ? true : false)
      {}
    },
    "doc.updateMany" => lambda { |db, a, _|
      r = db.doc_update_many(a["collection"], filter(a["filter"]), set: a["set"], inc: a["inc"])
      { "matched" => r["matched"], "modified" => r["modified"] }
    },
    "doc.delete" => ->(db, a, _) { db.doc_delete(a["collection"], a["id"]); {} },
    "doc.createIndex" => lambda { |db, a, _|
      db.doc_create_index(a["collection"], a["indexName"], a["field"], unique: a["unique"] ? true : false)
      {}
    },
    "doc.dropIndex" => ->(db, a, _) { db.doc_drop_index(a["collection"], a["indexName"]); {} },
    "doc.listIndexes" => lambda { |db, a, _|
      { "indexes" => db.doc_list_indexes(a["collection"]).map { |i| { "name" => i["index_name"], "field" => i["field"] } } }
    },
    "doc.analyze" => ->(db, a, _) { { "document_count" => db.doc_analyze(a["collection"])["document_count"] } },
    "doc.aggregate" => ->(db, a, _) { { "docs" => db.doc_aggregate(a["collection"], a["pipeline"].map { |s| stage(s) }) } },

    "vec.createCollection" => lambda { |db, a, _|
      db.vector_create_collection(a["collection"], a["dimension"], metric: a["metric"])
      {}
    },
    "vec.dropCollection" => ->(db, a, _) { db.vector_drop_collection(a["collection"]); {} },
    "vec.listCollections" => ->(db, _a, _) { { "names" => db.vector_list_collections } },
    "vec.upsert" => ->(db, a, _) { db.vector_upsert(a["collection"], a["id"], a["vector"], metadata: a["metadata"]); {} },
    "vec.get" => ->(db, a, _) { found(db.vector_get(a["collection"], a["id"]), "id", "vector", "metadata") },
    "vec.delete" => ->(db, a, _) { db.vector_delete(a["collection"], a["id"]); {} },
    "vec.search" => lambda { |db, a, _|
      hits = db.vector_search(a["collection"], a["vector"], a["topK"], filter: a["filter"])
      { "ids" => hits.map { |h| h["id"] }, "scores" => hits.map { |h| h["score"] } }
    },
    "vec.describeCollection" => lambda { |db, a, _|
      d = db.vector_describe_collection(a["collection"])
      { "dimension" => d["dimension"], "metric" => d["metric"], "count" => d["count"] }
    },
    "vec.listVectors" => lambda { |db, a, _|
      page = db.vector_list_vectors(a["collection"])
      { "ids" => page["vectors"].map { |v| v["id"] }, "total" => page["total"] }
    },

    "graph.create" => ->(db, a, _) { db.graph_create(a["graph"]); {} },
    "graph.drop" => ->(db, a, _) { db.graph_drop(a["graph"]); {} },
    "graph.listGraphs" => ->(db, _a, _) { { "names" => db.graph_list } },
    "graph.addNode" => lambda { |db, a, _|
      db.graph_add_node(a["graph"], a["id"], labels: a["labels"] || [], properties: a["properties"] || {})
      {}
    },
    "graph.getNode" => ->(db, a, _) { found(db.graph_get_node(a["graph"], a["id"]), "id", "labels", "properties") },
    "graph.deleteNode" => ->(db, a, _) { db.graph_delete_node(a["graph"], a["id"]); {} },
    "graph.addEdge" => lambda { |db, a, _|
      db.graph_add_edge(a["graph"], a["id"], a["from"], a["to"], a["label"], properties: a["properties"] || {})
      {}
    },
    "graph.getEdge" => ->(db, a, _) { found(db.graph_get_edge(a["graph"], a["id"]), "id", "from", "to", "label", "properties") },
    "graph.deleteEdge" => ->(db, a, _) { db.graph_delete_edge(a["graph"], a["id"]); {} },
    "graph.neighbors" => lambda { |db, a, _|
      ns = db.graph_neighbors(a["graph"], a["nodeId"], direction: a["direction"] || "outgoing", label: a["label"])
      { "nodeIds" => ns.map { |n| n["node_id"] }, "edgeIds" => ns.map { |n| n["edge_id"] } }
    },
    "graph.degree" => lambda { |db, a, _|
      { "degree" => db.graph_degree(a["graph"], a["nodeId"], direction: a["direction"] || "outgoing") }
    },
    "graph.traverse" => lambda { |db, a, _|
      t = db.graph_traverse(a["graph"], a["start"], direction: a["direction"] || "outgoing", max_depth: a["maxDepth"])
      { "ids" => t["nodes"].map { |n| n["id"] }, "depths" => t["nodes"].to_h { |n| [n["id"], n["depth"]] } }
    },
    "graph.shortestPath" => lambda { |db, a, _|
      p = db.graph_shortest_path(a["graph"], a["from"], a["to"])
      { "found" => p["found"], "hops" => p["hops"], "nodePath" => p["node_path"], "edgePath" => p["edge_path"] }
    },
    "graph.weightedShortestPath" => lambda { |db, a, _|
      p = db.graph_weighted_shortest_path(a["graph"], a["from"], a["to"], weight_property: a["weightProperty"])
      { "found" => p["found"], "totalCost" => p["total_cost"], "nodePath" => p["node_path"], "edgePath" => p["edge_path"] }
    },
    "graph.listNodes" => lambda { |db, a, _|
      page = db.graph_list_nodes(a["graph"])
      { "ids" => page["nodes"].map { |n| n["id"] }, "labels" => page["nodes"].to_h { |n| [n["id"], n["labels"]] },
        "total" => page["total"] }
    },
    "graph.listEdges" => lambda { |db, a, _|
      page = db.graph_list_edges(a["graph"])
      { "ids" => page["edges"].map { |e| e["id"] }, "labels" => page["edges"].to_h { |e| [e["id"], e["label"]] },
        "total" => page["total"] }
    },
    "graph.query" => lambda { |db, a, _|
      q = db.graph_query(a["graph"], a["cypher"])
      { "columns" => q["columns"], "rows" => q["rows"] }
    },

    "sql.execute" => ->(db, a, _) { { "rowsAffected" => db.execute(a["sql"]).rows_affected } },
    "sql.query" => lambda { |db, a, _|
      rows = db.query(a["sql"])
      { "columns" => rows.columns, "rows" => rows.rows }
    },

    "cache.ping" => ->(db, _a, _) { db.cache_ping; {} },
    "cache.set" => ->(db, a, _) { db.cache_set(a["namespace"], a["key"], utf8_bytes(a["value"]), ttl_ms: a["ttlMs"]); {} },
    "cache.get" => ->(db, a, _) { value(db.cache_get(a["namespace"], a["key"])) },
    "cache.delete" => ->(db, a, _) { { "deleted" => db.cache_delete(a["namespace"], a["key"]) } },
    "cache.exists" => ->(db, a, _) { { "exists" => db.cache_exists?(a["namespace"], a["key"]) } },
    "cache.ttl" => lambda { |db, a, _|
      ttl = db.cache_ttl(a["namespace"], a["key"])
      ttl.nil? ? { "hasTtl" => false } : { "hasTtl" => true, "ttlMs" => ttl }
    },
    "cache.clearNamespace" => ->(db, a, _) { { "cleared" => db.cache_clear_namespace(a["namespace"]) } },
    "cache.incr" => ->(db, a, _) { { "value" => db.cache_incr(a["namespace"], a["key"], a["by"]) } },
    "cache.expire" => ->(db, a, _) { { "updated" => db.cache_expire(a["namespace"], a["key"], a["ttlMs"]) } },
    "cache.persist" => ->(db, a, _) { { "persisted" => db.cache_persist(a["namespace"], a["key"]) } },
    "cache.setNx" => lambda { |db, a, _|
      { "set" => db.cache_set_nx(a["namespace"], a["key"], utf8_bytes(a["value"]), ttl_ms: a["ttlMs"]) }
    },
    "cache.keys" => ->(db, a, _) { { "keys" => db.cache_keys(a["namespace"], pattern: a["pattern"]).map { |k| k["key"] } } },

    "cache.lPush" => ->(db, a, _) { { "length" => db.cache_lpush(a["namespace"], a["key"], a["values"].map { |v| utf8_bytes(v) }) } },
    "cache.rPush" => ->(db, a, _) { { "length" => db.cache_rpush(a["namespace"], a["key"], a["values"].map { |v| utf8_bytes(v) }) } },
    "cache.lPop" => ->(db, a, _) { value(db.cache_lpop(a["namespace"], a["key"])) },
    "cache.rPop" => ->(db, a, _) { value(db.cache_rpop(a["namespace"], a["key"])) },
    "cache.lRange" => lambda { |db, a, _|
      { "values" => db.cache_lrange(a["namespace"], a["key"], a["start"], a["stop"]).map { |b| text(b) } }
    },
    "cache.lLen" => ->(db, a, _) { { "length" => db.cache_llen(a["namespace"], a["key"]) } },
    "cache.lIndex" => ->(db, a, _) { value(db.cache_lindex(a["namespace"], a["key"], a["index"])) },

    "cache.sAdd" => ->(db, a, _) { { "added" => db.cache_sadd(a["namespace"], a["key"], a["members"].map { |v| utf8_bytes(v) }) } },
    "cache.sRem" => ->(db, a, _) { { "removed" => db.cache_srem(a["namespace"], a["key"], a["members"].map { |v| utf8_bytes(v) }) } },
    "cache.sIsMember" => lambda { |db, a, _|
      { "isMember" => db.cache_sismember?(a["namespace"], a["key"], utf8_bytes(a["member"])) }
    },
    "cache.sCard" => ->(db, a, _) { { "cardinality" => db.cache_scard(a["namespace"], a["key"]) } },
    "cache.sMembers" => ->(db, a, _) { { "members" => db.cache_smembers(a["namespace"], a["key"]).map { |b| text(b) } } },

    "cache.hSet" => ->(db, a, _) { { "created" => db.cache_hset(a["namespace"], a["key"], pairs(a["entries"])) } },
    "cache.hGet" => ->(db, a, _) { value(db.cache_hget(a["namespace"], a["key"], utf8_bytes(a["field"]))) },
    "cache.hDel" => ->(db, a, _) { { "deleted" => db.cache_hdel(a["namespace"], a["key"], a["fields"].map { |v| utf8_bytes(v) }) } },
    "cache.hGetAll" => lambda { |db, a, _|
      { "entries" => db.cache_hgetall(a["namespace"], a["key"]).map { |f, v| [text(f), text(v)] } }
    },
    "cache.hExists" => ->(db, a, _) { { "exists" => db.cache_hexists?(a["namespace"], a["key"], utf8_bytes(a["field"])) } },
    "cache.hLen" => ->(db, a, _) { { "length" => db.cache_hlen(a["namespace"], a["key"]) } },

    "cache.xAdd" => ->(db, a, _) { { "id" => db.cache_xadd(a["namespace"], a["key"], pairs(a["fields"])) } },
    "cache.xLen" => ->(db, a, _) { { "length" => db.cache_xlen(a["namespace"], a["key"]) } },
    "cache.xRange" => lambda { |db, a, _|
      { "entries" => db.cache_xrange(a["namespace"], a["key"], a["start"], a["end"]).map { |e| entry(e) } }
    },
    "cache.xRead" => lambda { |db, a, ctx|
      { "entries" => db.cache_xread(a["namespace"], a["key"], ctx.fetch(a["afterStep"])["id"]).map { |e| entry(e) } }
    },
    "cache.xDel" => lambda { |db, a, ctx|
      { "deleted" => db.cache_xdel(a["namespace"], a["key"], a["idsFromSteps"].map { |s| ctx.fetch(s)["id"] }) }
    },
    "cache.xTrim" => ->(db, a, _) { { "trimmed" => db.cache_xtrim(a["namespace"], a["key"], a["maxLen"]) } },
    # Consumer groups are refused by the server by name; the raw request path is how a user reaches the operation.
    "cache.xGroup" => lambda { |db, a, _|
      db.request({ "Cache" => { "XGroup" => { "namespace" => a["namespace"], "key" => a["key"], "command" => a["command"] } } })
      {}
    },

    "llm.schema" => ->(db, a, _) { { "rendered" => db.llm_schema(format: a["format"]).to_s } },
    "llm.context" => lambda { |db, a, _|
      { "rendered" => db.llm_context(a["sources"].map { |s| s.transform_keys(&:to_sym) }, format: a["format"]).to_s }
    },

    "admin.ping" => ->(db, _a, _) { db.admin_ping; {} },
    "admin.status" => ->(db, _a, _) { { "status" => db.admin_status } }
  }.freeze

  def emit(obj)
    $stdout.write("#{JSON.generate(obj)}\n")
  end

  def main(argv)
    host, port, user, secret = argv
    scenario = JSON.parse($stdin.read)
    db = TriCoreDB.connect(host: host, port: Integer(port), user: user, secret: secret)
    results = {}
    begin
      scenario["steps"].each do |step|
        fn = ACTIONS[step["action"]]
        if fn.nil?
          emit("id" => step["id"], "status" => "unsupported", "error" => "no Ruby SDK method for action #{step['action']}")
          next
        end
        begin
          out = fn.call(db, step["args"] || {}, results)
          results[step["id"]] = out
          emit("id" => step["id"], "status" => "ok", "value" => out)
        rescue StandardError => e
          emit("id" => step["id"], "status" => "error", "error" => "#{e.class.name}: #{e.message}")
        end
      end
    ensure
      db.close
    end
  end
end

begin
  ConformanceRunner.main(ARGV)
rescue StandardError => e
  warn "ruby runner fatal: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
  exit 1
end
