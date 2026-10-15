use crate::{CoreError, CoreResult, diagnostic, pointer_part, required};
use serde_json::{Value as Json, json};
use toml_edit::{DocumentMut, Item, Table, Value};

pub(crate) fn parse(content: &str) -> CoreResult<DocumentMut> {
    content.parse::<DocumentMut>().map_err(|error| {
        let mut detail = diagnostic("error", "toml_syntax", "", error.to_string());
        if let Some(span) = error.span() {
            let prefix = &content[..span.start.min(content.len())];
            detail["line"] = json!(prefix.bytes().filter(|b| *b == b'\n').count() + 1);
            detail["column"] = json!(prefix.rsplit('\n').next().unwrap_or("").chars().count() + 1);
        }
        CoreError::diagnostics(
            "invalid_toml",
            "The document is not valid TOML",
            vec![detail],
        )
    })
}

pub(crate) fn typed(content: &str) -> CoreResult<toml::Value> {
    parse(content)?;
    toml::from_str(content).map_err(|error| CoreError::new("invalid_toml", error.to_string()))
}

pub(crate) fn tokens(pointer: &str) -> CoreResult<Vec<String>> {
    if pointer.is_empty() {
        return Ok(Vec::new());
    }
    if !pointer.starts_with('/') {
        return Err(CoreError::new(
            "invalid_pointer",
            "JSON Pointer must be empty or start with /",
        ));
    }
    pointer[1..]
        .split('/')
        .map(|part| {
            let mut output = String::new();
            let mut chars = part.chars();
            while let Some(ch) = chars.next() {
                if ch != '~' {
                    output.push(ch);
                    continue;
                }
                match chars.next() {
                    Some('0') => output.push('~'),
                    Some('1') => output.push('/'),
                    _ => {
                        return Err(CoreError::new(
                            "invalid_pointer",
                            "Invalid JSON Pointer escape; use ~0 or ~1",
                        ));
                    }
                }
            }
            Ok(output)
        })
        .collect()
}

pub(crate) fn literal(value: &toml::Value) -> String {
    match value {
        toml::Value::String(value) => serde_json::to_string(value).unwrap_or_default(),
        toml::Value::Integer(value) => value.to_string(),
        toml::Value::Float(value) if value.is_nan() => "nan".to_string(),
        toml::Value::Float(value) if value.is_infinite() => if value.is_sign_negative() {
            "-inf"
        } else {
            "inf"
        }
        .to_string(),
        toml::Value::Float(value) => {
            let mut output = value.to_string();
            if !output.contains(['.', 'e', 'E']) {
                output.push_str(".0");
            }
            output
        }
        toml::Value::Boolean(value) => value.to_string(),
        toml::Value::Datetime(value) => value.to_string(),
        toml::Value::Array(values) => format!(
            "[{}]",
            values.iter().map(literal).collect::<Vec<_>>().join(", ")
        ),
        toml::Value::Table(values) => format!(
            "{{ {} }}",
            values
                .iter()
                .map(|(key, value)| {
                    format!(
                        "{} = {}",
                        serde_json::to_string(key).unwrap_or_default(),
                        literal(value)
                    )
                })
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn parse_replacement(text: &str) -> CoreResult<Item> {
    let mut document = parse(&format!("__value = {text}"))?;
    if document.as_table().len() != 1 {
        return Err(CoreError::new(
            "invalid_value",
            "Provide exactly one TOML value",
        ));
    }
    let item = document
        .as_table_mut()
        .remove("__value")
        .ok_or_else(|| CoreError::new("invalid_value", "Expected a TOML value"))?;
    if !item.is_value() {
        return Err(CoreError::new(
            "invalid_value",
            "Expected a TOML value literal",
        ));
    }
    Ok(item)
}

fn array_index(segment: &str, len: usize, append: bool) -> CoreResult<usize> {
    if segment == "-" && append {
        return Ok(len);
    }
    if segment.len() > 1 && segment.starts_with('0') {
        return Err(CoreError::new(
            "invalid_pointer",
            "Array indices cannot contain leading zeros",
        ));
    }
    let index = segment
        .parse::<usize>()
        .map_err(|_| CoreError::new("invalid_pointer", "Expected an array index"))?;
    if index > len || (index == len && !append) {
        return Err(CoreError::new("not_found", "Array index is out of bounds"));
    }
    Ok(index)
}

fn preserve_decor(replacement: &Item, existing: Option<&Item>) -> Item {
    let mut new_item = replacement.clone();
    if let (Some(new), Some(old)) = (new_item.as_value_mut(), existing.and_then(Item::as_value)) {
        *new.decor_mut() = old.decor().clone();
    }
    new_item
}

fn new_table_item(replacement: &Item) -> Item {
    replacement
        .as_value()
        .and_then(Value::as_inline_table)
        .map(|table| Item::Table(table.clone().into_table()))
        .unwrap_or_else(|| replacement.clone())
}

fn modify_table(table: &mut Table, parts: &[String], replacement: Option<&Item>) -> CoreResult<()> {
    let key = &parts[0];
    if parts.len() == 1 {
        match replacement {
            Some(item) => {
                let existing = table.get(key);
                let item = preserve_decor(item, existing);
                let item = if existing.is_none() {
                    new_table_item(&item)
                } else {
                    item
                };
                // Assign the value in place to preserve the existing key's
                // prefix/suffix decoration (including leading comments).
                if let Some(existing) = table.get_mut(key) {
                    *existing = item;
                } else {
                    table.insert(key, item);
                }
            }
            None => {
                if table.remove(key).is_none() {
                    return Err(CoreError::new(
                        "not_found",
                        format!("Key does not exist: {key}"),
                    ));
                }
            }
        }
        return Ok(());
    }
    if !table.contains_key(key) {
        if replacement.is_none() {
            return Err(CoreError::new(
                "not_found",
                format!("Key does not exist: {key}"),
            ));
        }
        let mut child = Table::new();
        child.set_implicit(true);
        table.insert(key, Item::Table(child));
    }
    modify_item(
        table
            .get_mut(key)
            .ok_or_else(|| CoreError::new("not_found", key))?,
        &parts[1..],
        replacement,
    )
}

fn modify_item(item: &mut Item, parts: &[String], replacement: Option<&Item>) -> CoreResult<()> {
    match item {
        Item::Table(table) => modify_table(table, parts, replacement),
        Item::Value(value) => modify_value(value, parts, replacement.and_then(Item::as_value)),
        Item::ArrayOfTables(tables) => {
            let index = array_index(&parts[0], tables.len(), false)?;
            if parts.len() == 1 {
                if replacement.is_none() {
                    tables.remove(index);
                    return Ok(());
                }
                let replacement = replacement
                    .and_then(Item::as_value)
                    .and_then(Value::as_inline_table)
                    .ok_or_else(|| {
                        CoreError::new(
                            "type_mismatch",
                            "An array-of-tables element must be a table",
                        )
                    })?;
                *tables
                    .get_mut(index)
                    .ok_or_else(|| CoreError::new("not_found", "Array item missing"))? =
                    replacement.clone().into_table();
                return Ok(());
            }
            modify_table(
                tables
                    .get_mut(index)
                    .ok_or_else(|| CoreError::new("not_found", "Array item missing"))?,
                &parts[1..],
                replacement,
            )
        }
        Item::None => Err(CoreError::new("not_found", "The pointer does not exist")),
    }
}

fn modify_value(
    value: &mut Value,
    parts: &[String],
    replacement: Option<&Value>,
) -> CoreResult<()> {
    match value {
        Value::InlineTable(table) => {
            let key = &parts[0];
            if parts.len() == 1 {
                match replacement {
                    Some(new) => {
                        let mut new = new.clone();
                        if let Some(old) = table.get(key) {
                            *new.decor_mut() = old.decor().clone();
                        }
                        if let Some(existing) = table.get_mut(key) {
                            *existing = new;
                        } else {
                            table.insert(key, new);
                        }
                    }
                    None => {
                        if table.remove(key).is_none() {
                            return Err(CoreError::new("not_found", "The pointer does not exist"));
                        }
                    }
                }
            } else {
                if !table.contains_key(key) && replacement.is_some() {
                    table.insert(key, Value::InlineTable(toml_edit::InlineTable::new()));
                }
                let child = table
                    .get_mut(key)
                    .ok_or_else(|| CoreError::new("not_found", "The pointer does not exist"))?;
                modify_value(child, &parts[1..], replacement)?;
            }
            Ok(())
        }
        Value::Array(array) => {
            let index = array_index(
                &parts[0],
                array.len(),
                parts.len() == 1 && replacement.is_some(),
            )?;
            if parts.len() == 1 {
                match replacement {
                    Some(new) if index == array.len() => array.push(new.clone()),
                    Some(new) => {
                        let mut new = new.clone();
                        if let Some(old) = array.get(index) {
                            *new.decor_mut() = old.decor().clone();
                        }
                        array.replace(index, new);
                    }
                    None => {
                        array.remove(index);
                    }
                }
                Ok(())
            } else {
                modify_value(
                    array
                        .get_mut(index)
                        .ok_or_else(|| CoreError::new("not_found", "Array item missing"))?,
                    &parts[1..],
                    replacement,
                )
            }
        }
        _ => Err(CoreError::new(
            "type_mismatch",
            "Cannot descend through a scalar value",
        )),
    }
}

pub(crate) fn edit(request: &Json) -> CoreResult<Json> {
    let content = required(request, "content")?;
    let parts = tokens(required(request, "pointer")?)?;
    let action = required(request, "action")?;
    let replacement = match action {
        "set" => Some(parse_replacement(required(request, "value_toml")?)?),
        "unset" => None,
        _ => {
            return Err(CoreError::new(
                "invalid_request",
                "action must be set or unset",
            ));
        }
    };
    let mut document = parse(content)?;
    if parts.is_empty() {
        let table = replacement
            .as_ref()
            .and_then(Item::as_value)
            .and_then(Value::as_inline_table)
            .ok_or_else(|| {
                CoreError::new(
                    "invalid_value",
                    "Replacing the document root requires an inline table value",
                )
            })?;
        *document.as_table_mut() = table.clone().into_table();
    } else {
        modify_table(document.as_table_mut(), &parts, replacement.as_ref())?;
    }
    let mut output = document.to_string();
    if content.contains("\r\n") && !content.replace("\r\n", "").contains('\n') {
        output = output.replace("\r\n", "\n").replace('\n', "\r\n");
    }
    let diagnostics = crate::schema::validate(&output)?;
    Ok(json!({"content":output,"diagnostics":diagnostics}))
}

fn inspect_node(value: &toml::Value, pointer: &str, key: &str) -> Json {
    let kind = match value {
        toml::Value::Table(_) => "object",
        toml::Value::Array(_) => "array",
        toml::Value::String(_) => "string",
        toml::Value::Integer(_) => "integer",
        toml::Value::Float(_) => "float",
        toml::Value::Boolean(_) => "boolean",
        toml::Value::Datetime(_) => "datetime",
    };
    let mut node = json!({"key":key,"pointer":pointer,"kind":kind,"value_toml":literal(value)});
    match value {
        toml::Value::Table(table) => {
            node["children"] = Json::Array(
                table
                    .iter()
                    .map(|(key, value)| {
                        inspect_node(value, &format!("{pointer}/{}", pointer_part(key)), key)
                    })
                    .collect(),
            )
        }
        toml::Value::Array(array) => {
            node["children"] = Json::Array(
                array
                    .iter()
                    .enumerate()
                    .map(|(i, value)| {
                        inspect_node(value, &format!("{pointer}/{i}"), &i.to_string())
                    })
                    .collect(),
            )
        }
        toml::Value::String(value) => node["value"] = json!(value),
        toml::Value::Boolean(value) => node["value"] = json!(value),
        _ => node["value"] = json!(literal(value)),
    }
    node
}

pub(crate) fn inspect(request: &Json) -> CoreResult<Json> {
    let document = typed(required(request, "content")?)?;
    let pointer = request.get("pointer").and_then(Json::as_str).unwrap_or("");
    let parts = tokens(pointer)?;
    let mut current = &document;
    for part in &parts {
        current = match current {
            toml::Value::Table(table) => table.get(part),
            toml::Value::Array(array) => array.get(array_index(part, array.len(), false)?),
            _ => None,
        }
        .ok_or_else(|| CoreError::new("not_found", format!("Pointer does not exist: {pointer}")))?;
    }
    Ok(inspect_node(
        current,
        pointer,
        parts.last().map(String::as_str).unwrap_or(""),
    ))
}
