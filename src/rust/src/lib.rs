use extendr_api::prelude::*;
use neo4rs::{query, BoltType, ConfigBuilder, Graph, Node, Path, Relation, Row, UnboundedRelation};
use serde_json::Value;
use std::collections::HashMap;
use std::time::Instant;
use tokio::runtime::Runtime;

/// A live connection to a Neo4j database.
///
/// Wraps a `neo4rs::Graph` (which internally pools Bolt connections) together
/// with a dedicated Tokio runtime. The whole thing is handed to R as an
/// external pointer, so R owns the handle and Rust owns the lifetime.
struct Neo4jConnection {
    graph: Graph,
    rt: Runtime,
}

/// Open a connection. `uri` is a Bolt URI, e.g. "neo4j://localhost:7687"
/// or "127.0.0.1:7687". When `database` is non-empty it selects the default
/// database for the session; an empty string uses the server default
/// ("neo4j"). Returns an external pointer that R holds onto.
#[extendr]
fn bolt_connect(
    uri: &str,
    user: &str,
    password: &str,
    database: &str,
) -> std::result::Result<ExternalPtr<Neo4jConnection>, Error> {
    let rt = Runtime::new().map_err(|e| Error::Other(e.to_string()))?;

    let mut builder = ConfigBuilder::default().uri(uri).user(user).password(password);
    if !database.is_empty() {
        builder = builder.db(database);
    }
    let config = builder
        .build()
        .map_err(|e| Error::Other(format!("Invalid connection config: {e}")))?;

    // neo4rs 0.9's `Graph::connect` is synchronous; run it inside the runtime
    // so any pool/routing setup that needs a reactor has one.
    let graph = rt
        .block_on(async { Graph::connect(config) })
        .map_err(|e| Error::Other(format!("Neo4j connect failed: {e}")))?;
    Ok(ExternalPtr::new(Neo4jConnection { graph, rt }))
}

/// Run a parameterized Cypher statement and collect every row.
///
/// `params` is a named R list; each element becomes a Cypher `$param`. Values
/// are converted straight to native Bolt types (no JSON round-trip), so the
/// query text is never string-interpolated (no injection, and the server can
/// cache the plan).
///
/// Returns a named list with `records` (one named list per row, values mapped
/// to native R structures), `keys` (column names), `count`, and `elapsed_ms`
/// (client-side round-trip time). The R side shapes `records` into either a
/// data frame or a nested list.
#[extendr]
fn bolt_run(
    conn: ExternalPtr<Neo4jConnection>,
    cypher: &str,
    params: Robj,
) -> std::result::Result<Robj, Error> {
    let mut q = query(cypher);
    if let Some(list) = params.as_list() {
        for (key, value) in list.iter() {
            if !key.is_empty() {
                q = q.param(key, robj_to_bolt(&value));
            }
        }
    }

    // The async block uses a boxed error so both the driver error
    // (neo4rs::Error) and the row-deserialization error (DeError) coerce
    // through `?` without a bespoke `From` impl.
    let start = Instant::now();
    let rows: std::result::Result<Vec<Row>, Box<dyn std::error::Error>> =
        conn.rt.block_on(async {
            let mut stream = conn.graph.execute(q).await?;
            let mut out = Vec::new();
            while let Some(row) = stream.next().await? {
                out.push(row);
            }
            Ok(out)
        });
    let rows = rows.map_err(|e| Error::Other(format!("Cypher execution failed: {e}")))?;
    let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;

    // Column names come from the first row. We use a serde_json round-trip
    // purely to read the top-level keys in order; the values themselves are
    // extracted natively via `get_value` (which preserves nodes/rels/paths).
    let keys: Vec<String> = match rows.first() {
        Some(row) => row
            .to::<Value>()
            .ok()
            .and_then(|v| v.as_object().map(|o| o.keys().cloned().collect()))
            .unwrap_or_default(),
        None => Vec::new(),
    };

    let mut records: Vec<Robj> = Vec::with_capacity(rows.len());
    for row in &rows {
        let vals: Vec<Robj> = keys.iter().map(|k| get_value(row, k)).collect();
        records.push(named_list(&keys, vals));
    }

    let out = named_list(
        &["records", "keys", "count", "elapsed_ms"],
        vec![
            List::from_values(records).into_robj(),
            keys.clone().into_robj(),
            r!(rows.len() as i32),
            r!(elapsed_ms),
        ],
    );
    Ok(out)
}

/// Extract a single row value by column name, probing the concrete Bolt types
/// in turn. Graph types (node/relationship/path) are probed first so they map
/// to structured objects rather than being flattened.
fn get_value(row: &Row, key: &str) -> Robj {
    if let Ok(n) = row.get::<Node>(key) {
        return node_to_robj(&n);
    }
    if let Ok(rel) = row.get::<Relation>(key) {
        return relation_to_robj(&rel);
    }
    if let Ok(rel) = row.get::<UnboundedRelation>(key) {
        return unbounded_relation_to_robj(&rel);
    }
    if let Ok(p) = row.get::<Path>(key) {
        return path_to_robj(&p);
    }
    if let Ok(b) = row.get::<bool>(key) {
        return r!(b);
    }
    if let Ok(i) = row.get::<i64>(key) {
        return int_to_robj(i);
    }
    if let Ok(f) = row.get::<f64>(key) {
        return r!(f);
    }
    if let Ok(s) = row.get::<String>(key) {
        return s.into_robj();
    }
    if let Ok(b) = row.get::<BoltType>(key) {
        return bolt_to_robj(&b);
    }
    na()
}

/// Convert any Bolt value into a native R structure: scalars -> length-1
/// vectors, lists -> vectors (or lists when heterogeneous), maps -> named
/// lists, and graph types -> classed named lists.
fn bolt_to_robj(v: &BoltType) -> Robj {
    match v {
        BoltType::Null(_) => na(),
        BoltType::Boolean(b) => r!(b.value),
        BoltType::Integer(i) => int_to_robj(i.value),
        BoltType::Float(f) => r!(f.value),
        BoltType::String(s) => s.value.clone().into_robj(),
        BoltType::List(l) => list_to_robj(&l.value),
        BoltType::Map(m) => {
            let mut names = Vec::with_capacity(m.value.len());
            let mut vals = Vec::with_capacity(m.value.len());
            for (k, val) in &m.value {
                names.push(k.value.clone());
                vals.push(bolt_to_robj(val));
            }
            named_list(&names, vals)
        }
        BoltType::Node(n) => node_to_robj(&Node::new(n.clone())),
        BoltType::Relation(rel) => relation_to_robj(&Relation::new(rel.clone())),
        BoltType::UnboundedRelation(rel) => {
            unbounded_relation_to_robj(&UnboundedRelation::new(rel.clone()))
        }
        BoltType::Path(p) => path_to_robj(&Path::new(p.clone())),
        // Temporal / spatial / bytes: best-effort textual form for now.
        other => format!("{other:?}").into_robj(),
    }
}

/// A Bolt list becomes a plain R vector when its elements share a scalar type
/// (a "neo4j list"), otherwise a generic R list.
fn list_to_robj(items: &[BoltType]) -> Robj {
    if !items.is_empty() {
        if items.iter().all(|x| matches!(x, BoltType::Integer(_))) {
            let vals: Vec<i64> = items
                .iter()
                .filter_map(|x| match x {
                    BoltType::Integer(i) => Some(i.value),
                    _ => None,
                })
                .collect();
            if vals.iter().all(|&i| i32::try_from(i).is_ok()) {
                return vals.iter().map(|&i| i as i32).collect::<Vec<_>>().into_robj();
            }
            return vals.iter().map(|&i| i as f64).collect::<Vec<_>>().into_robj();
        }
        if items.iter().all(|x| matches!(x, BoltType::Float(_))) {
            let vals: Vec<f64> = items
                .iter()
                .filter_map(|x| match x {
                    BoltType::Float(f) => Some(f.value),
                    _ => None,
                })
                .collect();
            return vals.into_robj();
        }
        if items.iter().all(|x| matches!(x, BoltType::Boolean(_))) {
            let vals: Vec<bool> = items
                .iter()
                .filter_map(|x| match x {
                    BoltType::Boolean(b) => Some(b.value),
                    _ => None,
                })
                .collect();
            return vals.into_robj();
        }
        if items.iter().all(|x| matches!(x, BoltType::String(_))) {
            let vals: Vec<String> = items
                .iter()
                .filter_map(|x| match x {
                    BoltType::String(s) => Some(s.value.clone()),
                    _ => None,
                })
                .collect();
            return vals.into_robj();
        }
    }
    let vals: Vec<Robj> = items.iter().map(bolt_to_robj).collect();
    List::from_values(vals).into_robj()
}

/// A node -> `list(id, labels, properties)` with class "neo4j_node".
fn node_to_robj(n: &Node) -> Robj {
    let props = properties(n.keys(), |k| n.get::<BoltType>(k).ok());
    let obj = named_list(
        &["id", "labels", "properties"],
        vec![
            int_to_robj(n.id()),
            n.labels()
                .iter()
                .map(|s| s.to_string())
                .collect::<Vec<_>>()
                .into_robj(),
            props,
        ],
    );
    with_class(obj, "neo4j_node")
}

/// A relationship -> `list(id, type, start, end, properties)`.
fn relation_to_robj(rel: &Relation) -> Robj {
    let props = properties(rel.keys(), |k| rel.get::<BoltType>(k).ok());
    let obj = named_list(
        &["id", "type", "start", "end", "properties"],
        vec![
            int_to_robj(rel.id()),
            rel.typ().to_string().into_robj(),
            int_to_robj(rel.start_node_id()),
            int_to_robj(rel.end_node_id()),
            props,
        ],
    );
    with_class(obj, "neo4j_relationship")
}

/// A relationship inside a path lacks endpoint ids -> `list(id, type, properties)`.
fn unbounded_relation_to_robj(rel: &UnboundedRelation) -> Robj {
    let props = properties(rel.keys(), |k| rel.get::<BoltType>(k).ok());
    let obj = named_list(
        &["id", "type", "properties"],
        vec![
            int_to_robj(rel.id()),
            rel.typ().to_string().into_robj(),
            props,
        ],
    );
    with_class(obj, "neo4j_relationship")
}

/// A path -> `list(nodes, relationships)` with class "neo4j_path".
fn path_to_robj(p: &Path) -> Robj {
    let nodes: Vec<Robj> = p.nodes().iter().map(node_to_robj).collect();
    let rels: Vec<Robj> = p.rels().iter().map(unbounded_relation_to_robj).collect();
    let obj = named_list(
        &["nodes", "relationships"],
        vec![
            List::from_values(nodes).into_robj(),
            List::from_values(rels).into_robj(),
        ],
    );
    with_class(obj, "neo4j_path")
}

/// Build a named list of a graph entity's properties.
fn properties(keys: Vec<&str>, get: impl Fn(&str) -> Option<BoltType>) -> Robj {
    let mut names = Vec::with_capacity(keys.len());
    let mut vals = Vec::with_capacity(keys.len());
    for k in keys {
        if let Some(v) = get(k) {
            names.push(k.to_string());
            vals.push(bolt_to_robj(&v));
        }
    }
    named_list(&names, vals)
}

/// R's integer type is 32-bit; fall back to double for larger Bolt integers.
fn int_to_robj(i: i64) -> Robj {
    if (i32::MIN as i64..=i32::MAX as i64).contains(&i) {
        r!(i as i32)
    } else {
        r!(i as f64)
    }
}

fn named_list<S: AsRef<str>>(names: &[S], values: Vec<Robj>) -> Robj {
    let names: Vec<&str> = names.iter().map(|s| s.as_ref()).collect();
    List::from_names_and_values(names, values)
        .unwrap()
        .into_robj()
}

fn with_class(mut obj: Robj, class: &str) -> Robj {
    obj.set_attrib("class", class).unwrap();
    obj
}

/// A length-1 logical NA.
fn na() -> Robj {
    let none: Option<bool> = None;
    none.into_robj()
}

/// Convert an R value into a Bolt parameter value.
///
/// A length-1 atomic vector becomes a Bolt scalar; a longer atomic vector
/// becomes a Bolt list; a named list becomes a Bolt map and an unnamed list a
/// Bolt list. `NULL` and `NA` become Bolt Null. This mirrors JSON auto-unboxing
/// without needing an R JSON library.
fn robj_to_bolt(x: &Robj) -> BoltType {
    if x.is_null() {
        return null_bolt();
    }

    // Lists: named -> map, unnamed -> list.
    if let Some(list) = x.as_list() {
        let has_names = x.names().is_some();
        if has_names {
            let mut m: HashMap<String, BoltType> = HashMap::with_capacity(list.len());
            for (key, value) in list.iter() {
                m.insert(key.to_string(), robj_to_bolt(&value));
            }
            return m.into();
        }
        let items: Vec<BoltType> = list.values().map(|v| robj_to_bolt(&v)).collect();
        return items.into();
    }

    // Atomic vectors -> scalar (length 1) or Bolt list.
    let items: Vec<BoltType> = match x.rtype() {
        Rtype::Logicals => x
            .as_logical_slice()
            .unwrap()
            .iter()
            .map(|b| if b.is_na() { null_bolt() } else { b.is_true().into() })
            .collect(),
        Rtype::Integers => x
            .as_integer_slice()
            .unwrap()
            .iter()
            .map(|&i| if i.is_na() { null_bolt() } else { (i as i64).into() })
            .collect(),
        Rtype::Doubles => x
            .as_real_slice()
            .unwrap()
            .iter()
            .map(|&f| if f.is_na() { null_bolt() } else { f.into() })
            .collect(),
        Rtype::Strings => x
            .as_str_iter()
            .unwrap()
            .map(|s| if s.is_na() { null_bolt() } else { s.to_string().into() })
            .collect(),
        // Anything else (functions, environments, ...) is not a valid parameter.
        _ => return null_bolt(),
    };

    match items.len() {
        1 => items.into_iter().next().unwrap(),
        _ => items.into(),
    }
}

fn null_bolt() -> BoltType {
    Option::<i64>::None.into()
}

// Macro to generate exports.
// This ensures exported functions are registered with R.
// See corresponding C code in `entrypoint.c`.
extendr_module! {
    mod Neo4jR;
    fn bolt_connect;
    fn bolt_run;
}
