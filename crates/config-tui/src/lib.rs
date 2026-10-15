use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph, Tabs, Wrap},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::{self, IsTerminal},
    path::PathBuf,
    sync::mpsc::{self, Receiver, TryRecvError},
    thread,
    time::Duration,
};

/// The editing target and the analysis context are deliberately independent.
#[derive(Clone, Debug)]
pub struct Options {
    pub path: PathBuf,
    pub codex_home: Option<PathBuf>,
    pub cwd: Option<PathBuf>,
    pub profile: Option<String>,
    pub language: String,
}

/// Run the terminal editor. Ratatui restores raw mode and the alternate screen
/// on normal errors and panic unwinding as well as a normal exit.
pub fn run(options: Options) -> io::Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(io::Error::other(
            "The TUI requires an interactive terminal / TUI 需要交互式终端",
        ));
    }
    let mut app = App::new(options).map_err(io::Error::other)?;
    ratatui::run(|terminal| {
        loop {
            app.receive_feature_catalog();
            terminal.draw(|frame| app.draw(frame))?;
            if event::poll(Duration::from_millis(150))? {
                match event::read()? {
                    Event::Key(key) if key.kind != KeyEventKind::Release => match app.key(key) {
                        Ok(true) => return Ok(()),
                        Ok(false) => {}
                        Err(error) => app.show_error(error),
                    },
                    Event::Paste(text) => {
                        if let Some(Modal::Input { input, .. }) = &mut app.modal {
                            input.insert(&text);
                        }
                    }
                    _ => {}
                }
            }
        }
    })
}

fn api(request: Value) -> Result<Value, String> {
    let response = codex_config_core::dispatch(request);
    if response["ok"] == true {
        Ok(response["data"].clone())
    } else {
        let error = &response["error"];
        let mut message = format!(
            "{}: {}",
            error["code"].as_str().unwrap_or("error"),
            error["message"].as_str().unwrap_or("Operation failed")
        );
        if let Some(diagnostics) = error.get("diagnostics") {
            message.push_str(&format!("\n{}", pretty(diagnostics)));
        }
        Err(message)
    }
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_default()
}
fn text(value: &Value) -> &str {
    value.as_str().unwrap_or_default()
}
fn escape_pointer(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}
fn join_pointer(parent: &str, key: &str) -> String {
    format!("{parent}/{}", escape_pointer(key))
}
fn variants(schema: &Value) -> Option<&Vec<Value>> {
    schema
        .get("oneOf")
        .or_else(|| schema.get("anyOf"))
        .and_then(Value::as_array)
}

#[derive(Clone)]
struct Node {
    pointer: String,
    label: String,
    schema: Value,
    value: Option<Value>,
}
#[derive(Clone)]
struct Page {
    pointer: String,
    schema: Value,
    label: String,
}

struct App {
    options: Options,
    schema: Value,
    metadata: Value,
    categories: Vec<Value>,
    category: usize,
    pages: Vec<Page>,
    content: String,
    original: String,
    revision: Value,
    tree: Value,
    diagnostics: Value,
    selected: usize,
    focus: usize,
    tab: usize,
    query: String,
    status: String,
    modal: Option<Modal>,
    analysis: Value,
    backups: Vec<Value>,
    feature_stages: BTreeMap<String, String>,
    feature_enabled: BTreeMap<String, bool>,
    feature_version: Option<String>,
    feature_receiver: Option<Receiver<Result<Value, String>>>,
    scroll: u16,
    should_quit: bool,
}

#[derive(Clone)]
enum Pending {
    Quit,
    Open(PathBuf),
    Restore(String),
}

enum InputPurpose {
    StringValue(String),
    TomlValue(String),
    AddKey { parent: String, schema: Value },
    Search,
    OpenPath,
    Cwd,
    CodexHome,
    Profile,
    SchemaImport,
    RawDocument,
}

enum Choice {
    File(PathBuf),
    Variant { node: Box<Node>, schema: Value },
    Value { pointer: String, value: String },
    OpenCustom,
}

enum Modal {
    Input {
        title: String,
        input: TextInput,
        purpose: InputPurpose,
    },
    Menu {
        title: String,
        items: Vec<(String, Choice)>,
        selected: usize,
    },
    Text {
        title: String,
        body: String,
        scroll: u16,
    },
    Confirm {
        action: Pending,
    },
}

struct TextInput {
    value: String,
    cursor: usize,
}
impl TextInput {
    fn new(value: String) -> Self {
        let cursor = value.len();
        Self { value, cursor }
    }
    fn insert(&mut self, value: &str) {
        self.value.insert_str(self.cursor, value);
        self.cursor += value.len();
    }
    fn left(&mut self) {
        if let Some((index, _)) = self.value[..self.cursor].char_indices().next_back() {
            self.cursor = index;
        }
    }
    fn right(&mut self) {
        if let Some(character) = self.value[self.cursor..].chars().next() {
            self.cursor += character.len_utf8();
        }
    }
    fn backspace(&mut self) {
        let end = self.cursor;
        self.left();
        self.value.replace_range(self.cursor..end, "");
    }
    fn delete(&mut self) {
        if let Some(character) = self.value[self.cursor..].chars().next() {
            self.value
                .replace_range(self.cursor..self.cursor + character.len_utf8(), "");
        }
    }
    fn home(&mut self) {
        self.cursor = self.value[..self.cursor]
            .rfind('\n')
            .map_or(0, |index| index + 1);
    }
    fn end(&mut self) {
        self.cursor += self.value[self.cursor..]
            .find('\n')
            .unwrap_or(self.value.len() - self.cursor);
    }
    fn vertical(&mut self, down: bool) {
        let line_start = self.value[..self.cursor]
            .rfind('\n')
            .map_or(0, |index| index + 1);
        let column = self.value[line_start..self.cursor].chars().count();
        let target_start = if down {
            match self.value[self.cursor..].find('\n') {
                Some(index) => self.cursor + index + 1,
                None => return,
            }
        } else {
            if line_start == 0 {
                return;
            }
            self.value[..line_start - 1]
                .rfind('\n')
                .map_or(0, |index| index + 1)
        };
        let target_end = target_start
            + self.value[target_start..]
                .find('\n')
                .unwrap_or(self.value.len() - target_start);
        self.cursor = self.value[target_start..target_end]
            .char_indices()
            .nth(column)
            .map_or(target_end, |(index, _)| target_start + index);
    }
}

impl App {
    fn new(options: Options) -> Result<Self, String> {
        let mut app = Self {
            options,
            schema: json!({}),
            metadata: Value::Null,
            categories: vec![],
            category: 0,
            pages: vec![],
            content: String::new(),
            original: String::new(),
            revision: Value::Null,
            tree: json!({"kind":"object","children":[]}),
            diagnostics: json!([]),
            selected: 0,
            focus: 1,
            tab: 0,
            query: String::new(),
            status: String::new(),
            modal: None,
            analysis: Value::Null,
            backups: vec![],
            feature_stages: BTreeMap::new(),
            feature_enabled: BTreeMap::new(),
            feature_version: None,
            feature_receiver: None,
            scroll: 0,
            should_quit: false,
        };
        app.load_schema()?;
        app.load(app.options.path.clone())?;
        app.load_feature_catalog();
        Ok(app)
    }

    fn tr<'a>(&self, english: &'a str, chinese: &'a str) -> &'a str {
        if self.options.language == "zh" {
            chinese
        } else {
            english
        }
    }
    fn dirty(&self) -> bool {
        self.content != self.original
    }
    fn context(&self, op: &str) -> Value {
        let mut request = json!({"op":op});
        if let Some(value) = &self.options.codex_home {
            request["codex_home"] = json!(value);
        }
        if let Some(value) = &self.options.cwd {
            request["cwd"] = json!(value);
        }
        if let Some(value) = &self.options.profile {
            request["profile"] = json!(value);
        }
        request
    }

    fn load_feature_catalog(&mut self) {
        let (sender, receiver) = mpsc::channel();
        if thread::Builder::new()
            .name("codex-feature-catalog".into())
            .spawn(move || {
                let _ = sender.send(api(json!({"op":"feature_catalog"})));
            })
            .is_ok()
        {
            self.feature_receiver = Some(receiver);
        }
    }

    fn receive_feature_catalog(&mut self) {
        let Some(receiver) = &self.feature_receiver else {
            return;
        };
        match receiver.try_recv() {
            Ok(Ok(data)) => {
                self.feature_receiver = None;
                self.update_feature_stages(&data);
            }
            Ok(Err(_)) | Err(TryRecvError::Disconnected) => self.feature_receiver = None,
            Err(TryRecvError::Empty) => {}
        }
    }

    fn update_feature_stages(&mut self, data: &Value) {
        if data["available"] != true {
            // A failed or unsupported snapshot must not leave an old
            // enablement value looking like the current context's state.
            self.feature_enabled.clear();
            self.feature_stages.clear();
            self.feature_version = None;
            return;
        }
        let Some(features) = data["features"].as_array() else {
            self.feature_enabled.clear();
            self.feature_stages.clear();
            self.feature_version = None;
            return;
        };
        let mut stages = BTreeMap::new();
        let mut enabled = BTreeMap::new();
        for feature in features {
            let Some(name) = feature["name"].as_str() else {
                continue;
            };
            if name.is_empty() {
                continue;
            }
            if let Some(stage) = feature["stage"].as_str()
                && !stage.is_empty()
            {
                stages.insert(name.to_owned(), stage.to_owned());
            }
            if let Some(value) = feature["enabled"].as_bool() {
                enabled.insert(name.to_owned(), value);
            }
        }
        self.feature_stages = stages;
        self.feature_enabled = enabled;
        self.feature_version = data["context"]["version"].as_str().map(str::to_owned);
        // A manual feature snapshot is newer than a pending startup catalog.
        self.feature_receiver = None;
    }

    fn feature_stage(&self, pointer: &str) -> Option<&str> {
        let components: Vec<_> = pointer.strip_prefix('/')?.split('/').collect();
        let key = match components.as_slice() {
            ["features", key] | ["profiles", _, "features", key] => key,
            _ => return None,
        };
        let name = key.replace("~1", "/").replace("~0", "~");
        self.feature_stages.get(&name).map(String::as_str)
    }

    fn feature_enabled(&self, pointer: &str) -> Option<bool> {
        let components: Vec<_> = pointer.strip_prefix('/')?.split('/').collect();
        let key = match components.as_slice() {
            ["features", key] | ["profiles", _, "features", key] => key,
            _ => return None,
        };
        let name = key.replace("~1", "/").replace("~0", "~");
        self.feature_enabled.get(&name).copied()
    }

    fn load_schema(&mut self) -> Result<(), String> {
        let data = api(json!({"op":"schema"}))?;
        self.schema = data["form_schema"].clone();
        self.metadata = data["metadata"].clone();
        self.categories = data["categories"].as_array().cloned().unwrap_or_default();
        self.categories
            .push(json!({"id":"all","label_en":"All fields","label_zh":"所有字段"}));
        self.category = self.category.min(self.categories.len().saturating_sub(1));
        self.pages.clear();
        self.selected = 0;
        Ok(())
    }

    fn load(&mut self, path: PathBuf) -> Result<(), String> {
        let snapshot = api(json!({"op":"open","path":path}))?;
        self.options.path = PathBuf::from(
            snapshot["path"]
                .as_str()
                .unwrap_or(path.to_str().unwrap_or_default()),
        );
        self.content = text(&snapshot["content"]).to_owned();
        self.original = self.content.clone();
        self.revision = snapshot["revision"].clone();
        self.diagnostics = snapshot["diagnostics"].clone();
        self.refresh_tree();
        self.pages.clear();
        self.selected = 0;
        self.query.clear();
        self.backups.clear();
        self.analysis = Value::Null;
        self.status = if snapshot["exists"] == false {
            self.tr(
                "New draft; save to create the file",
                "新草稿，保存后创建文件",
            )
            .into()
        } else {
            self.tr("File loaded", "已加载文件").into()
        };
        Ok(())
    }

    fn refresh_tree(&mut self) {
        match api(json!({"op":"inspect","content":self.content})) {
            Ok(tree) => self.tree = tree,
            Err(error) => {
                self.tree = json!({"kind":"object","children":[]});
                self.status = error;
            }
        }
    }

    fn at(&self, pointer: &str) -> Option<&Value> {
        if pointer.is_empty() {
            return Some(&self.tree);
        }
        let mut node = &self.tree;
        for component in pointer.strip_prefix('/')?.split('/') {
            let key = component.replace("~1", "/").replace("~0", "~");
            node = node["children"]
                .as_array()?
                .iter()
                .find(|child| text(&child["key"]) == key)?;
        }
        Some(node)
    }

    fn visible_nodes(&self) -> Vec<Node> {
        if !self.query.is_empty() {
            let mut results = vec![];
            self.search_nodes(
                "",
                &self.schema,
                &self.query.to_lowercase(),
                0,
                &mut results,
            );
            return results;
        }
        if let Some(page) = self.pages.last() {
            return self.children(&page.pointer, &page.schema);
        }
        let mut nodes = self.children("", &self.schema);
        if let Some(keys) = self
            .categories
            .get(self.category)
            .and_then(|category| category["keys"].as_array())
        {
            nodes.retain(|node| {
                keys.iter()
                    .any(|key| key.as_str() == Some(node.label.as_str()))
            });
        }
        nodes
    }

    fn children(&self, pointer: &str, schema: &Value) -> Vec<Node> {
        let value = self.at(pointer);
        let effective = effective_schema(schema, value);
        if effective["type"] == "array" || value.is_some_and(|value| value["kind"] == "array") {
            return value
                .and_then(|value| value["children"].as_array())
                .map(|items| {
                    items
                        .iter()
                        .enumerate()
                        .map(|(index, item)| Node {
                            pointer: join_pointer(pointer, &index.to_string()),
                            label: format!("[{index}]"),
                            schema: item_schema(&effective, index),
                            value: Some(item.clone()),
                        })
                        .collect()
                })
                .unwrap_or_default();
        }
        let mut nodes = vec![];
        if let Some(properties) = effective["properties"].as_object() {
            for (key, schema) in properties {
                let path = join_pointer(pointer, key);
                nodes.push(Node {
                    value: self.at(&path).cloned(),
                    pointer: path,
                    label: key.clone(),
                    schema: schema.clone(),
                });
            }
        }
        if let Some(children) = value.and_then(|value| value["children"].as_array()) {
            for child in children {
                let key = text(&child["key"]);
                if nodes.iter().any(|node| node.label == key) {
                    continue;
                }
                nodes.push(Node {
                    pointer: join_pointer(pointer, key),
                    label: key.into(),
                    schema: effective
                        .get("additionalProperties")
                        .filter(|value| value.is_object())
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    value: Some(child.clone()),
                });
            }
        }
        nodes
    }

    fn search_nodes(
        &self,
        pointer: &str,
        schema: &Value,
        query: &str,
        depth: usize,
        results: &mut Vec<Node>,
    ) {
        if depth > 14 || results.len() > 4000 {
            return;
        }
        for node in self.children(pointer, schema) {
            if format!("{} {}", node.pointer, text(&node.schema["description"]))
                .to_lowercase()
                .contains(query)
            {
                results.push(node.clone());
            }
            let effective = effective_schema(&node.schema, node.value.as_ref());
            if is_container(&effective, node.value.as_ref()) {
                self.search_nodes(&node.pointer, &effective, query, depth + 1, results);
            }
        }
    }

    fn selected_node(&self) -> Option<Node> {
        self.visible_nodes().get(self.selected).cloned()
    }
    fn edit(&mut self, pointer: &str, value: Option<String>) -> Result<(), String> {
        let mut request = json!({"op":"edit","content":self.content,"pointer":pointer,"action":if value.is_some(){"set"}else{"unset"}});
        if let Some(value) = value {
            request["value_toml"] = json!(value);
        }
        let edited = api(request)?;
        self.content = text(&edited["content"]).into();
        self.diagnostics = edited["diagnostics"].clone();
        self.refresh_tree();
        self.selected = self
            .selected
            .min(self.visible_nodes().len().saturating_sub(1));
        self.status = self
            .tr("Draft updated; Ctrl+S saves", "草稿已更新；Ctrl+S 保存")
            .into();
        Ok(())
    }

    fn save(&mut self) -> Result<(), String> {
        let saved = api(
            json!({"op":"save","path":self.options.path,"content":self.content,"revision":self.revision}),
        )?;
        self.content = saved["content"].as_str().unwrap_or(&self.content).into();
        self.original = self.content.clone();
        self.revision = saved["revision"].clone();
        self.diagnostics = saved["diagnostics"].clone();
        self.refresh_tree();
        self.status = self
            .tr(
                "Saved with revision conflict protection",
                "已保存，写入前已检查版本冲突",
            )
            .into();
        Ok(())
    }

    fn show_error(&mut self, error: String) {
        self.modal = Some(Modal::Text {
            title: self.tr("Error", "错误").into(),
            body: error,
            scroll: 0,
        });
    }
    fn input(&mut self, title: String, value: String, purpose: InputPurpose) {
        self.modal = Some(Modal::Input {
            title,
            input: TextInput::new(value),
            purpose,
        });
    }
    fn show_text(&mut self, title: &str, body: String) {
        self.modal = Some(Modal::Text {
            title: title.into(),
            body,
            scroll: 0,
        });
    }
    fn request_pending(&mut self, action: Pending) -> Result<(), String> {
        if self.dirty() {
            self.modal = Some(Modal::Confirm { action });
            Ok(())
        } else {
            self.perform(action)
        }
    }
    fn perform(&mut self, action: Pending) -> Result<(), String> {
        match action {
            Pending::Quit => self.should_quit = true,
            Pending::Open(path) => self.load(path)?,
            Pending::Restore(id) => {
                api(
                    json!({"op":"restore","path":self.options.path,"backup_id":id,"revision":self.revision}),
                )?;
                self.load(self.options.path.clone())?;
                self.refresh_backups()?;
                self.status = self.tr("Backup restored", "已恢复备份").into();
            }
        }
        Ok(())
    }

    fn refresh_backups(&mut self) -> Result<(), String> {
        self.backups = api(json!({"op":"backups","path":self.options.path}))?["backups"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        self.selected = self.selected.min(self.backups.len().saturating_sub(1));
        Ok(())
    }
    fn refresh_analysis(&mut self) -> Result<(), String> {
        self.analysis = api(self.context("analyze"))?;
        self.scroll = 0;
        self.status = self
            .tr(
                "Analysis uses saved files; the editing draft is excluded",
                "覆盖分析读取已保存文件，不包含当前草稿",
            )
            .into();
        Ok(())
    }

    fn file_menu(&mut self) -> Result<(), String> {
        let paths = api(self.context("paths"))?;
        let mut items = vec![];
        for (key, label) in [
            ("user", self.tr("User", "用户")),
            ("system", self.tr("System", "系统")),
        ] {
            if let Some(path) = paths[key].as_str() {
                items.push((format!("{label}: {path}"), Choice::File(path.into())));
            }
        }
        let cwd = PathBuf::from(paths["cwd"].as_str().unwrap_or("."));
        let current_project = cwd.join(".codex").join("config.toml");
        items.push((
            format!(
                "{}: {}",
                self.tr("Current project", "当前项目"),
                current_project.display()
            ),
            Choice::File(current_project),
        ));
        if let Some(projects) = paths["projects"].as_array() {
            for path in projects.iter().filter_map(Value::as_str) {
                items.push((
                    format!("{}: {path}", self.tr("Project layer", "项目层")),
                    Choice::File(path.into()),
                ));
            }
        }
        if let Some(profiles) = paths["profiles"].as_array() {
            for profile in profiles {
                if let Some(path) = profile["path"].as_str() {
                    items.push((
                        format!("Profile {}: {path}", text(&profile["name"])),
                        Choice::File(path.into()),
                    ));
                }
            }
        }
        items.push((
            self.tr("Open another file…", "指定其他文件…").into(),
            Choice::OpenCustom,
        ));
        self.modal = Some(Modal::Menu {
            title: self
                .tr(
                    "Editing target (does not activate a Profile)",
                    "编辑目标（不会激活 Profile）",
                )
                .into(),
            items,
            selected: 0,
        });
        Ok(())
    }

    fn activate(&mut self, node: Node, choose_variant: bool) -> Result<(), String> {
        if let Some(alternatives) = variants(&node.schema)
            && (choose_variant || node.value.is_none())
        {
            let items = alternatives
                .iter()
                .enumerate()
                .map(|(index, schema)| {
                    (
                        format!("{}: {}", index + 1, schema_label(schema)),
                        Choice::Variant {
                            node: Box::new(node.clone()),
                            schema: schema.clone(),
                        },
                    )
                })
                .collect();
            self.modal = Some(Modal::Menu {
                title: format!("{} {}", self.tr("Choose type", "选择类型"), node.pointer),
                items,
                selected: 0,
            });
            return Ok(());
        }
        let schema = effective_schema(&node.schema, node.value.as_ref());
        if is_container(&schema, node.value.as_ref()) {
            self.query.clear();
            self.pages.push(Page {
                pointer: node.pointer,
                schema,
                label: node.label,
            });
            self.selected = 0;
            self.focus = 1;
        } else if let Some(values) = schema["enum"].as_array() {
            let items = values
                .iter()
                .filter(|value| !value.is_null())
                .map(|value| {
                    let value = json_to_toml(value);
                    (
                        value.clone(),
                        Choice::Value {
                            pointer: node.pointer.clone(),
                            value,
                        },
                    )
                })
                .collect();
            self.modal = Some(Modal::Menu {
                title: node.pointer,
                items,
                selected: 0,
            });
        } else if schema["type"] == "boolean"
            || node
                .value
                .as_ref()
                .is_some_and(|value| value["kind"] == "boolean")
        {
            let current = node
                .value
                .as_ref()
                .is_some_and(|value| text(&value["value_toml"]) == "true");
            self.edit(&node.pointer, Some((!current).to_string()))?;
        } else if schema["type"] == "string"
            || node
                .value
                .as_ref()
                .is_some_and(|value| value["kind"] == "string")
        {
            let value = node
                .value
                .as_ref()
                .and_then(|value| value["value"].as_str())
                .unwrap_or_default()
                .to_string();
            self.input(
                format!(
                    "{} · {}",
                    node.pointer,
                    self.tr("String (Ctrl+S applies)", "字符串（Ctrl+S 应用）")
                ),
                value,
                InputPurpose::StringValue(node.pointer),
            );
        } else {
            let value = node
                .value
                .as_ref()
                .map(|value| text(&value["value_toml"]).to_string())
                .unwrap_or_else(|| default_toml(&schema));
            self.input(
                format!("{} · TOML", node.pointer),
                value,
                InputPurpose::TomlValue(node.pointer),
            );
        }
        Ok(())
    }

    fn add(&mut self) -> Result<(), String> {
        let page = self.pages.last().cloned().unwrap_or(Page {
            pointer: "".into(),
            schema: self.schema.clone(),
            label: "".into(),
        });
        let schema = effective_schema(&page.schema, self.at(&page.pointer));
        if schema["type"] == "array"
            || self
                .at(&page.pointer)
                .is_some_and(|value| value["kind"] == "array")
        {
            let mut values = self
                .at(&page.pointer)
                .and_then(|value| value["children"].as_array())
                .map(|items| {
                    items
                        .iter()
                        .map(|item| text(&item["value_toml"]).to_owned())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let item = item_schema(&schema, values.len());
            values.push(default_toml(&item));
            self.edit(&page.pointer, Some(format!("[{}]", values.join(", "))))?;
            self.selected = values.len() - 1;
        } else if schema["additionalProperties"] != false {
            self.input(
                self.tr("New map key (Ctrl+S adds)", "新增键名（Ctrl+S 添加）")
                    .into(),
                String::new(),
                InputPurpose::AddKey {
                    parent: page.pointer,
                    schema: schema
                        .get("additionalProperties")
                        .filter(|value| value.is_object())
                        .cloned()
                        .unwrap_or_else(|| json!({"type":"string"})),
                },
            );
        } else {
            self.status = self
                .tr(
                    "This object only accepts the listed schema fields",
                    "此对象仅接受 Schema 中列出的字段",
                )
                .into();
        }
        Ok(())
    }

    fn reorder(&mut self, down: bool) -> Result<(), String> {
        let Some(page) = self.pages.last() else {
            return Ok(());
        };
        let pointer = page.pointer.clone();
        let Some(array) = self.at(&pointer).filter(|value| value["kind"] == "array") else {
            return Ok(());
        };
        let Some(children) = array["children"].as_array() else {
            return Ok(());
        };
        let target = if down {
            self.selected.saturating_add(1)
        } else {
            self.selected.saturating_sub(1)
        };
        if target >= children.len() || self.selected >= children.len() {
            return Ok(());
        }
        let mut values: Vec<_> = children
            .iter()
            .map(|value| text(&value["value_toml"]).to_string())
            .collect();
        values.swap(self.selected, target);
        self.edit(&pointer, Some(format!("[{}]", values.join(", "))))?;
        self.selected = target;
        Ok(())
    }
}

fn schema_kind(schema: &Value) -> &str {
    schema["type"].as_str().unwrap_or_else(|| {
        if schema.get("properties").is_some() || schema.get("additionalProperties").is_some() {
            "object"
        } else {
            "value"
        }
    })
}
fn schema_label(schema: &Value) -> String {
    if let Some(title) = schema["title"].as_str() {
        return title.into();
    }
    if let Some(values) = schema["enum"].as_array() {
        return values
            .iter()
            .map(json_to_toml)
            .collect::<Vec<_>>()
            .join(" | ");
    }
    schema_kind(schema).into()
}
fn effective_schema(schema: &Value, value: Option<&Value>) -> Value {
    if let Some(alternatives) = variants(schema) {
        if let Some(value) = value {
            let kind = text(&value["kind"]);
            if let Some(matched) = alternatives.iter().find(|alternative| {
                let expected = schema_kind(alternative);
                (expected == kind || (kind == "float" && expected == "number"))
                    && alternative["enum"].as_array().is_none_or(|values| {
                        values
                            .iter()
                            .any(|candidate| json_to_toml(candidate) == text(&value["value_toml"]))
                    })
            }) {
                return effective_schema(matched, Some(value));
            }
        }
        if let Some(first) = alternatives.first() {
            return effective_schema(first, value);
        }
    }
    schema.clone()
}
fn is_container(schema: &Value, value: Option<&Value>) -> bool {
    matches!(schema_kind(schema), "object" | "array")
        || value.is_some_and(|value| matches!(text(&value["kind"]), "object" | "array"))
}
fn item_schema(schema: &Value, index: usize) -> Value {
    if let Some(items) = schema["prefixItems"]
        .as_array()
        .or_else(|| schema["items"].as_array())
    {
        return items.get(index).cloned().unwrap_or_else(|| json!({}));
    }
    schema
        .get("items")
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| json!({"type":"string"}))
}
fn default_toml(schema: &Value) -> String {
    let schema = effective_schema(schema, None);
    if let Some(value) = schema
        .get("const")
        .or_else(|| schema["enum"].as_array().and_then(|items| items.first()))
    {
        return json_to_toml(value);
    }
    match schema_kind(&schema) {
        "object" => "{}".into(),
        "array" => "[]".into(),
        "boolean" => "false".into(),
        "integer" | "number" => schema
            .get("minimum")
            .map(json_to_toml)
            .unwrap_or_else(|| "0".into()),
        _ => "\"\"".into(),
    }
}
fn json_to_toml(value: &Value) -> String {
    match value {
        Value::Array(items) => format!(
            "[{}]",
            items
                .iter()
                .map(json_to_toml)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Value::Object(items) => format!(
            "{{ {} }}",
            items
                .iter()
                .map(|(key, value)| format!("{} = {}", json!(key), json_to_toml(value)))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Value::Null => "\"\"".into(),
        _ => value.to_string(),
    }
}

impl App {
    fn key(&mut self, key: KeyEvent) -> Result<bool, String> {
        if self.modal.is_some() {
            self.modal_key(key)?;
            return Ok(self.should_quit);
        }
        let control = key.modifiers.contains(KeyModifiers::CONTROL);
        if control {
            match key.code {
                KeyCode::Char('s') => self.save()?,
                KeyCode::Char('o') => self.file_menu()?,
                KeyCode::Char('c') => self.request_pending(Pending::Quit)?,
                KeyCode::Tab => self.switch_tab((self.tab + 1) % 4)?,
                _ => {}
            }
            return Ok(self.should_quit);
        }
        match key.code {
            KeyCode::Char('q') => self.request_pending(Pending::Quit)?,
            KeyCode::F(number @ 1..=4) => self.switch_tab(usize::from(number - 1))?,
            KeyCode::Char(number @ '1'..='4') => self.switch_tab(number as usize - '1' as usize)?,
            KeyCode::Tab => {
                self.focus = (self.focus + 1) % 3;
                self.scroll = 0;
            }
            KeyCode::BackTab => {
                self.focus = (self.focus + 2) % 3;
                self.scroll = 0;
            }
            KeyCode::Char('l') => {
                self.options.language = if self.options.language == "zh" {
                    "en"
                } else {
                    "zh"
                }
                .into()
            }
            KeyCode::Char('o') => self.file_menu()?,
            KeyCode::Char('?') => self.help(),
            KeyCode::Char('p') => {
                let data = api(json!({"op":"diff","before":self.original,"after":self.content}))?;
                self.show_text(
                    self.tr("Unsaved changes", "未保存的更改"),
                    text(&data["diff"]).into(),
                );
            }
            KeyCode::Char('!') => {
                let data = api(json!({"op":"validate","content":self.content}))?;
                self.show_text(self.tr("Validation", "校验结果"), pretty(&data));
            }
            KeyCode::Char('/') if self.tab == 0 => self.input(
                self.tr("Search all schema fields", "搜索全部 Schema 字段")
                    .into(),
                self.query.clone(),
                InputPurpose::Search,
            ),
            KeyCode::Char('r') if self.tab == 0 => self.input(
                self.tr(
                    "TOML document · Ctrl+S applies draft",
                    "TOML 原文 · Ctrl+S 应用到草稿",
                )
                .into(),
                self.content.clone(),
                InputPurpose::RawDocument,
            ),
            KeyCode::Esc | KeyCode::Left if self.tab == 0 => {
                if !self.query.is_empty() {
                    self.query.clear();
                } else {
                    self.pages.pop();
                }
                self.selected = 0;
                self.scroll = 0;
            }
            KeyCode::Up | KeyCode::Char('k') => self.move_selection(false),
            KeyCode::Down | KeyCode::Char('j') => self.move_selection(true),
            KeyCode::PageUp => self.scroll = self.scroll.saturating_sub(10),
            KeyCode::PageDown => self.scroll = self.scroll.saturating_add(10),
            KeyCode::Home => {
                self.selected = 0;
                self.scroll = 0;
            }
            KeyCode::End => {
                self.selected = self.row_count().saturating_sub(1);
            }
            KeyCode::Enter | KeyCode::Right => match self.tab {
                0 if self.focus == 0 => {
                    self.focus = 1;
                    self.selected = 0;
                }
                0 => {
                    if let Some(node) = self.selected_node() {
                        self.activate(node, false)?;
                    }
                }
                1 => self.refresh_analysis()?,
                2 => {
                    if let Some(backup) = self.backups.get(self.selected) {
                        self.modal = Some(Modal::Confirm {
                            action: Pending::Restore(text(&backup["id"]).into()),
                        });
                    }
                }
                3 => self.setting()?,
                _ => {}
            },
            KeyCode::Char(' ') if self.tab == 0 => {
                if let Some(node) = self.selected_node() {
                    let schema = effective_schema(&node.schema, node.value.as_ref());
                    if schema["type"] == "boolean"
                        || node
                            .value
                            .as_ref()
                            .is_some_and(|value| value["kind"] == "boolean")
                    {
                        self.activate(node, false)?;
                    }
                }
            }
            KeyCode::Char('v') if self.tab == 0 => {
                if let Some(node) = self.selected_node() {
                    self.activate(node, true)?;
                }
            }
            KeyCode::Char('e') if self.tab == 0 => {
                if let Some(node) = self.selected_node() {
                    let value = node
                        .value
                        .as_ref()
                        .map(|value| text(&value["value_toml"]).into())
                        .unwrap_or_else(|| default_toml(&node.schema));
                    self.input(
                        format!("{} · TOML", node.pointer),
                        value,
                        InputPurpose::TomlValue(node.pointer),
                    );
                }
            }
            KeyCode::Char('d' | 'u') | KeyCode::Delete if self.tab == 0 => {
                if let Some(node) = self.selected_node() {
                    self.edit(&node.pointer, None)?;
                }
            }
            KeyCode::Char('a') if self.tab == 0 => self.add()?,
            KeyCode::Char('[') if self.tab == 0 => self.reorder(false)?,
            KeyCode::Char(']') if self.tab == 0 => self.reorder(true)?,
            KeyCode::Char('a' | 'r') if self.tab == 1 => self.refresh_analysis()?,
            KeyCode::Char('r') if self.tab == 2 => self.refresh_backups()?,
            _ => {}
        }
        Ok(self.should_quit)
    }

    fn switch_tab(&mut self, tab: usize) -> Result<(), String> {
        self.tab = tab;
        self.selected = 0;
        self.scroll = 0;
        match tab {
            1 => self.refresh_analysis()?,
            2 => self.refresh_backups()?,
            _ => {}
        }
        Ok(())
    }
    fn row_count(&self) -> usize {
        match self.tab {
            0 => {
                if self.focus == 0 {
                    self.categories.len()
                } else {
                    self.visible_nodes().len()
                }
            }
            2 => self.backups.len(),
            3 => 9,
            _ => 0,
        }
    }
    fn move_selection(&mut self, down: bool) {
        if self.tab == 1 || (self.tab == 0 && self.focus == 2) {
            self.scroll = if down {
                self.scroll.saturating_add(1)
            } else {
                self.scroll.saturating_sub(1)
            };
            return;
        }
        if self.tab == 0 && self.focus == 0 {
            self.category = if down {
                (self.category + 1).min(self.categories.len().saturating_sub(1))
            } else {
                self.category.saturating_sub(1)
            };
            self.pages.clear();
            self.query.clear();
            self.selected = 0;
        } else {
            self.selected = if down {
                (self.selected + 1).min(self.row_count().saturating_sub(1))
            } else {
                self.selected.saturating_sub(1)
            };
        }
        self.scroll = 0;
    }

    fn modal_key(&mut self, key: KeyEvent) -> Result<(), String> {
        let Some(mut modal) = self.modal.take() else {
            return Ok(());
        };
        match &mut modal {
            Modal::Text { scroll, .. } => match key.code {
                KeyCode::Esc | KeyCode::Enter | KeyCode::Char('q') => return Ok(()),
                KeyCode::Up | KeyCode::Char('k') => *scroll = scroll.saturating_sub(1),
                KeyCode::Down | KeyCode::Char('j') => *scroll = scroll.saturating_add(1),
                KeyCode::PageUp => *scroll = scroll.saturating_sub(10),
                KeyCode::PageDown => *scroll = scroll.saturating_add(10),
                KeyCode::Home => *scroll = 0,
                _ => {}
            },
            Modal::Confirm { action } => match key.code {
                KeyCode::Esc | KeyCode::Char('c' | 'q') => return Ok(()),
                KeyCode::Char('s') if self.dirty() => {
                    self.save()?;
                    self.perform(action.clone())?;
                    return Ok(());
                }
                KeyCode::Char('d') if self.dirty() => {
                    self.perform(action.clone())?;
                    return Ok(());
                }
                KeyCode::Char('y') | KeyCode::Enter if !self.dirty() => {
                    self.perform(action.clone())?;
                    return Ok(());
                }
                _ => {}
            },
            Modal::Menu {
                items, selected, ..
            } => match key.code {
                KeyCode::Esc | KeyCode::Char('q') => return Ok(()),
                KeyCode::Up | KeyCode::Char('k') => *selected = selected.saturating_sub(1),
                KeyCode::Down | KeyCode::Char('j') => {
                    *selected = (*selected + 1).min(items.len().saturating_sub(1))
                }
                KeyCode::Home => *selected = 0,
                KeyCode::End => *selected = items.len().saturating_sub(1),
                KeyCode::Enter if *selected < items.len() => {
                    let (_, choice) = items.remove(*selected);
                    match choice {
                        Choice::File(path) => self.request_pending(Pending::Open(path))?,
                        Choice::OpenCustom => self.input(
                            self.tr("Config file path", "配置文件路径").into(),
                            String::new(),
                            InputPurpose::OpenPath,
                        ),
                        Choice::Value { pointer, value } => self.edit(&pointer, Some(value))?,
                        Choice::Variant { mut node, schema } => {
                            self.edit(&node.pointer, Some(default_toml(&schema)))?;
                            node.schema = schema;
                            node.value = self.at(&node.pointer).cloned();
                            if is_container(&node.schema, node.value.as_ref()) {
                                self.activate(*node, false)?;
                            }
                        }
                    }
                    return Ok(());
                }
                _ => {}
            },
            Modal::Input { input, purpose, .. } => {
                let submit = (key.modifiers.contains(KeyModifiers::CONTROL)
                    && key.code == KeyCode::Char('s'))
                    || (key.code == KeyCode::Enter
                        && !matches!(
                            purpose,
                            InputPurpose::StringValue(_)
                                | InputPurpose::TomlValue(_)
                                | InputPurpose::RawDocument
                        ));
                if submit {
                    match self.submit_input(purpose, &input.value) {
                        Ok(()) => return Ok(()),
                        Err(error) => self.status = error,
                    }
                } else {
                    match key.code {
                        KeyCode::Esc => return Ok(()),
                        KeyCode::Backspace => input.backspace(),
                        KeyCode::Delete => input.delete(),
                        KeyCode::Left => input.left(),
                        KeyCode::Right => input.right(),
                        KeyCode::Up => input.vertical(false),
                        KeyCode::Down => input.vertical(true),
                        KeyCode::Home => input.home(),
                        KeyCode::End => input.end(),
                        KeyCode::Enter => input.insert("\n"),
                        KeyCode::Tab => input.insert("    "),
                        KeyCode::Char('a') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            input.cursor = 0
                        }
                        KeyCode::Char('e') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            input.cursor = input.value.len()
                        }
                        KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            input.value.clear();
                            input.cursor = 0;
                        }
                        KeyCode::Char(character)
                            if !key
                                .modifiers
                                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                        {
                            input.insert(&character.to_string())
                        }
                        _ => {}
                    }
                }
            }
        }
        self.modal = Some(modal);
        Ok(())
    }

    fn submit_input(&mut self, purpose: &InputPurpose, input: &str) -> Result<(), String> {
        match purpose {
            InputPurpose::StringValue(pointer) => {
                self.edit(pointer, Some(json!(input).to_string()))?
            }
            InputPurpose::TomlValue(pointer) => self.edit(pointer, Some(input.into()))?,
            InputPurpose::AddKey { parent, schema } => {
                if input.is_empty() {
                    return Err(self.tr("A key cannot be empty", "键名不能为空").into());
                }
                let pointer = join_pointer(parent, input);
                if self.at(&pointer).is_some() {
                    return Err(self.tr("That key already exists", "该键已存在").into());
                }
                self.edit(&pointer, Some(default_toml(schema)))?;
                self.selected = self
                    .visible_nodes()
                    .iter()
                    .position(|node| node.pointer == pointer)
                    .unwrap_or(0);
            }
            InputPurpose::Search => {
                self.query = input.into();
                self.selected = 0;
                self.focus = 1;
            }
            InputPurpose::OpenPath => {
                if !input.trim().is_empty() {
                    self.request_pending(Pending::Open(input.trim().into()))?;
                }
            }
            InputPurpose::Cwd => {
                self.options.cwd = if input.trim().is_empty() {
                    None
                } else {
                    Some(input.trim().into())
                };
                self.feature_enabled.clear();
                self.analysis = Value::Null;
            }
            InputPurpose::CodexHome => {
                self.options.codex_home = if input.trim().is_empty() {
                    None
                } else {
                    Some(input.trim().into())
                };
                self.feature_enabled.clear();
                self.analysis = Value::Null;
            }
            InputPurpose::Profile => {
                self.options.profile = if input.trim().is_empty() {
                    None
                } else {
                    Some(input.trim().into())
                };
                self.feature_enabled.clear();
                self.analysis = Value::Null;
            }
            InputPurpose::SchemaImport => {
                let data =
                    api(json!({"op":"schema_update","action":"import","path":input.trim()}))?;
                self.load_schema()?;
                self.show_text(
                    self.tr("Schema import", "导入 Schema"),
                    pretty(&data["metadata"]),
                );
            }
            InputPurpose::RawDocument => {
                let data = api(json!({"op":"validate","content":input}))?;
                let tree = api(json!({"op":"inspect","content":input}))?;
                self.content = input.into();
                self.diagnostics = data["diagnostics"].clone();
                self.tree = tree;
                self.status = self
                    .tr(
                        "TOML draft updated; Ctrl+S saves",
                        "TOML 草稿已更新；Ctrl+S 保存",
                    )
                    .into();
            }
        }
        Ok(())
    }

    fn setting(&mut self) -> Result<(), String> {
        match self.selected {
            0 => {
                self.options.language = if self.options.language == "zh" {
                    "en"
                } else {
                    "zh"
                }
                .into()
            }
            1 => self.input(
                self.tr(
                    "Analysis working directory (empty = process directory)",
                    "分析工作目录（留空使用进程目录）",
                )
                .into(),
                self.options
                    .cwd
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_default(),
                InputPurpose::Cwd,
            ),
            2 => self.input(
                self.tr(
                    "CODEX_HOME (empty = automatic)",
                    "CODEX_HOME（留空自动发现）",
                )
                .into(),
                self.options
                    .codex_home
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_default(),
                InputPurpose::CodexHome,
            ),
            3 => self.input(
                self.tr(
                    "Analysis Profile (empty = none)",
                    "分析 Profile（留空不选）",
                )
                .into(),
                self.options.profile.clone().unwrap_or_default(),
                InputPurpose::Profile,
            ),
            4 | 5 | 7 => {
                let action = match self.selected {
                    4 => "check",
                    5 => "update",
                    _ => "reset",
                };
                let data = api(json!({"op":"schema_update","action":action}))?;
                self.load_schema()?;
                self.show_text(
                    self.tr("Schema", "Schema"),
                    pretty(data.get("metadata").unwrap_or(&data)),
                );
            }
            6 => self.input(
                self.tr("Schema JSON file path", "Schema JSON 文件路径")
                    .into(),
                String::new(),
                InputPurpose::SchemaImport,
            ),
            8 => {
                let data = api(self.context("features"))?;
                self.update_feature_stages(&data);
                self.show_text(
                    self.tr("Codex features snapshot", "Codex 功能状态快照"),
                    pretty(&data),
                );
            }
            _ => {}
        }
        Ok(())
    }

    fn help(&mut self) {
        self.show_text(self.tr("Keyboard help", "键盘帮助"), self.tr(
            "1–4 / F1–F4   Editor / Analysis / Backups / Settings\nTab / Shift+Tab  Categories / Fields / Details\n↑↓ or j/k       Navigate; details scroll when focused\nEnter / →       Expand object/array, edit scalar, select enum\nSpace           Toggle boolean\nv               Choose a union type (replaces this value)\na               Add dynamic map key or array element\nd / u / Delete  Remove setting or array element\n[ / ]           Move array element up/down\ne               Edit selected value as TOML\nr               Edit complete TOML draft\nEsc / ←         Parent; clear search\n/               Search all schema fields\nCtrl+S          Save file (inside input: apply draft value)\nCtrl+O / o      Switch editing file\np               Preview draft diff (may contain sensitive values)\n!               Validate draft\nl               Switch English / Chinese\nq / Ctrl+C      Quit with unsaved-draft handling\n\nInput: Ctrl+S applies; Esc cancels; Enter inserts a newline for values.\nSchema defaults are documentation only and are never materialized automatically.\nAnalysis reads saved files and shows unknown runtime/cloud/MDM inputs.\nProfile used for analysis does not change the editing target.",
            "1–4 / F1–F4   编辑 / 分析 / 备份 / 设置\nTab / Shift+Tab  分类 / 字段 / 详情\n↑↓ 或 j/k       导航；详情获得焦点后滚动\nEnter / →       展开对象和数组、编辑值、选择枚举\n空格            切换布尔值\nv               选择联合类型（替换当前值）\na               添加动态键或数组元素\nd / u / Delete  取消字段设置或删除数组元素\n[ / ]           上移 / 下移数组元素\ne               按 TOML 编辑选中值\nr               编辑完整 TOML 草稿\nEsc / ←         返回上层；清除搜索\n/               搜索全部 Schema 字段\nCtrl+S          保存文件（输入框内为应用到草稿）\nCtrl+O / o      切换编辑文件\np               预览草稿差异（可能包含敏感值）\n!               校验草稿\nl               切换中英文\nq / Ctrl+C      退出并处理未保存草稿\n\n输入框：Ctrl+S 应用，Esc 取消；值输入框中 Enter 插入换行。\nSchema 默认值仅作为说明，不会自动写入配置。\n覆盖分析读取已保存文件，运行时、云端、MDM 未知项会单独标记。\n分析所选 Profile 不影响当前编辑目标。"
        ).into());
    }

    fn draw(&mut self, frame: &mut Frame) {
        let area = frame.area();
        if area.width < 30 || area.height < 9 {
            frame.render_widget(
                Paragraph::new(self.tr(
                    "Resize terminal to at least 30×9. q exits.",
                    "请将终端调整到至少 30×9。q 退出。",
                )),
                area,
            );
            return;
        }
        let sections = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(2),
                Constraint::Length(2),
                Constraint::Min(3),
                Constraint::Length(3),
            ])
            .split(area);
        let dirty = if self.dirty() { " ●" } else { "" };
        let title = Line::from(vec![
            Span::styled(
                " CODEX CONFIGURATOR",
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(format!("{dirty}  {}", self.options.path.display())),
        ]);
        frame.render_widget(Paragraph::new(title), sections[0]);
        let titles = [
            self.tr("1 Editor", "1 编辑"),
            self.tr("2 Analysis", "2 分析"),
            self.tr("3 Backups", "3 备份"),
            self.tr("4 Settings", "4 设置"),
        ];
        frame.render_widget(
            Tabs::new(titles)
                .select(self.tab)
                .highlight_style(
                    Style::default()
                        .fg(Color::Cyan)
                        .add_modifier(Modifier::BOLD),
                )
                .divider(" │ "),
            sections[1],
        );
        match self.tab {
            0 => self.draw_editor(frame, sections[2]),
            1 => self.draw_analysis(frame, sections[2]),
            2 => self.draw_backups(frame, sections[2]),
            _ => self.draw_settings(frame, sections[2]),
        }
        let footer = format!(
            "{}\n{}\n{}",
            self.tr(
                "Ctrl+S save · o file · / search · Tab focus · ? help · q quit",
                "Ctrl+S 保存 · o 文件 · / 搜索 · Tab 焦点 · ? 帮助 · q 退出"
            ),
            self.tr(
                "Enter edit · a add · d unset · v type · [ ] reorder · p diff",
                "Enter 编辑 · a 添加 · d 取消设置 · v 类型 · [ ] 排序 · p 差异"
            ),
            self.status
        );
        frame.render_widget(
            Paragraph::new(footer).style(Style::default().fg(Color::Gray)),
            sections[3],
        );
        if self.modal.is_some() {
            self.draw_modal(frame, area);
        }
    }

    fn panel<'a>(&self, title: impl Into<Line<'a>>, focused: bool) -> Block<'a> {
        Block::default()
            .borders(Borders::ALL)
            .title(title)
            .border_style(Style::default().fg(if focused {
                Color::Cyan
            } else {
                Color::DarkGray
            }))
    }

    fn draw_editor(&self, frame: &mut Frame, area: Rect) {
        if area.width < 90 {
            match self.focus {
                0 => self.draw_categories(frame, area),
                2 => self.draw_details(frame, area),
                _ => self.draw_fields(frame, area),
            }
        } else {
            let columns = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(20),
                    Constraint::Percentage(35),
                    Constraint::Percentage(45),
                ])
                .split(area);
            self.draw_categories(frame, columns[0]);
            self.draw_fields(frame, columns[1]);
            self.draw_details(frame, columns[2]);
        }
    }

    fn draw_categories(&self, frame: &mut Frame, area: Rect) {
        let language_key = if self.options.language == "zh" {
            "label_zh"
        } else {
            "label_en"
        };
        let items = self.categories.iter().map(|category| {
            ListItem::new(
                category[language_key]
                    .as_str()
                    .unwrap_or(text(&category["id"]))
                    .to_owned(),
            )
        });
        let list = List::new(items)
            .block(self.panel(self.tr("Categories", "分类"), self.focus == 0))
            .highlight_style(Style::default().bg(Color::DarkGray).fg(Color::White))
            .highlight_symbol("› ");
        frame.render_stateful_widget(
            list,
            area,
            &mut ListState::default().with_selected(Some(self.category)),
        );
    }

    fn draw_fields(&self, frame: &mut Frame, area: Rect) {
        let nodes = self.visible_nodes();
        let title = if !self.query.is_empty() {
            format!("/ {} · {}", self.query, nodes.len())
        } else if let Some(page) = self.pages.last() {
            format!("{} {}", page.label, page.pointer)
        } else {
            self.tr("Fields", "字段").into()
        };
        let rows = nodes.iter().map(|node| {
            let effective = effective_schema(&node.schema, node.value.as_ref());
            let marker = if node.value.is_some() { "●" } else { "○" };
            let branch = if is_container(&effective, node.value.as_ref()) {
                " ›"
            } else {
                ""
            };
            let label = if self.query.is_empty() {
                &node.label
            } else {
                &node.pointer
            };
            let mut spans = vec![
                Span::styled(
                    format!("{marker} "),
                    Style::default().fg(if node.value.is_some() {
                        Color::Cyan
                    } else {
                        Color::DarkGray
                    }),
                ),
                Span::raw(format!("{label}{branch}")),
            ];
            if let Some(stage) = self.feature_stage(&node.pointer) {
                let color = match stage {
                    "stable" => Color::Green,
                    "experimental" => Color::Magenta,
                    "under development" => Color::Yellow,
                    "deprecated" => Color::LightYellow,
                    "removed" => Color::Red,
                    _ => Color::Cyan,
                };
                spans.push(Span::styled(
                    format!(" [{stage}]"),
                    Style::default().fg(color),
                ));
            }
            if let Some(enabled) = self.feature_enabled(&node.pointer) {
                spans.push(Span::styled(
                    format!(" [{enabled}]"),
                    Style::default().fg(if enabled {
                        Color::Green
                    } else {
                        Color::DarkGray
                    }),
                ));
            }
            ListItem::new(Line::from(spans))
        });
        let list = List::new(rows)
            .block(self.panel(title, self.focus == 1))
            .highlight_style(Style::default().bg(Color::DarkGray).fg(Color::White))
            .highlight_symbol("› ");
        frame.render_stateful_widget(
            list,
            area,
            &mut ListState::default().with_selected(if nodes.is_empty() {
                None
            } else {
                Some(self.selected.min(nodes.len() - 1))
            }),
        );
        if nodes.is_empty() {
            let inner = Rect {
                x: area.x + 2,
                y: area.y + 2,
                width: area.width.saturating_sub(4),
                height: area.height.saturating_sub(4),
            };
            frame.render_widget(
                Paragraph::new(self.tr(
                    "No fields. Press a to add a map key or array element; Esc returns.",
                    "无字段。按 a 添加动态键或数组元素；Esc 返回。",
                ))
                .wrap(Wrap { trim: false }),
                inner,
            );
        }
    }

    fn draw_details(&self, frame: &mut Frame, area: Rect) {
        let body = if let Some(node) = self.selected_node() {
            let effective = effective_schema(&node.schema, node.value.as_ref());
            let mut body = format!(
                "{}\n{}: {}\n\n{}\n\n{}\n{}",
                node.pointer,
                self.tr("Type", "类型"),
                schema_label(&effective),
                node.schema["description"].as_str().unwrap_or(self.tr(
                    "Official schema key; description unavailable.",
                    "官方 Schema 字段；暂无说明。"
                )),
                self.tr("Value in this file", "此文件中的值"),
                node.value
                    .as_ref()
                    .map(|value| text(&value["value_toml"]))
                    .unwrap_or(self.tr(
                        "Not set (inherits lower layers)",
                        "未设置（由低优先级层提供）"
                    ))
            );
            if let Some(stage) = self.feature_stage(&node.pointer) {
                body.push_str(&format!(
                    "\n\n{}: {stage}\n{}: codex features list{}",
                    self.tr("Feature stage", "功能阶段"),
                    self.tr("Source", "来源"),
                    self.feature_version
                        .as_ref()
                        .map(|version| format!(" ({version})"))
                        .unwrap_or_default(),
                ));
            }
            if let Some(enabled) = self.feature_enabled(&node.pointer) {
                body.push_str(&format!(
                    "\n\n{}: {}",
                    self.tr("Feature state", "功能状态"),
                    if enabled {
                        self.tr("Enabled", "已启用")
                    } else {
                        self.tr("Disabled", "未启用")
                    },
                ));
            }
            if let Some(value) = effective.get("default") {
                body.push_str(&format!(
                    "\n\n{}: {}",
                    self.tr(
                        "Schema default (not written)",
                        "Schema 默认值（不会自动写入）"
                    ),
                    json_to_toml(value)
                ));
            }
            if variants(&node.schema).is_some() {
                body.push_str(&format!(
                    "\n\n{}",
                    self.tr("v chooses a union type", "按 v 选择联合类型")
                ));
            }
            if node.schema.get("x-recursive-ref").is_some() {
                body.push_str(&format!(
                    "\n\n{}",
                    self.tr(
                        "Recursive schema reference: use e to edit the value as TOML.",
                        "递归 Schema 引用：可按 e 以 TOML 编辑该值。"
                    )
                ));
            }
            body.push_str(&format!(
                "\n\n{}",
                self.tr(
                    "Descriptions retain the official source language.",
                    "字段说明保留官方原文。"
                )
            ));
            body
        } else {
            format!(
                "{}\n\n{}",
                self.tr(
                    "○ Unset  ● Set\nChoose a field to inspect its schema and current value.",
                    "○ 未设置  ● 已设置\n选择字段查看 Schema 和当前值。"
                ),
                pretty(&self.diagnostics)
            )
        };
        frame.render_widget(
            Paragraph::new(body)
                .wrap(Wrap { trim: false })
                .scroll((self.scroll, 0))
                .block(self.panel(self.tr("Details", "详情"), self.focus == 2)),
            area,
        );
    }

    fn draw_analysis(&self, frame: &mut Frame, area: Rect) {
        let title = self.tr(
            "Saved configuration overlay · Enter refresh · ↑↓ scroll",
            "已保存配置覆盖分析 · Enter 刷新 · ↑↓ 滚动",
        );
        let body = if self.analysis.is_null() {
            self.tr(
                "Press Enter to analyze saved files.",
                "按 Enter 分析已保存文件。",
            )
            .into()
        } else {
            pretty(&self.analysis)
        };
        frame.render_widget(
            Paragraph::new(body)
                .wrap(Wrap { trim: false })
                .scroll((self.scroll, 0))
                .block(self.panel(title, true)),
            area,
        );
    }

    fn draw_backups(&self, frame: &mut Frame, area: Rect) {
        let rows = self.backups.iter().map(|backup| {
            ListItem::new(format!(
                "{}  {}\n  {}",
                text(&backup["id"]),
                text(&backup["created_at"]),
                text(&backup["path"])
            ))
        });
        let list = List::new(rows)
            .block(self.panel(
                self.tr(
                    "Backups · Enter restore · r refresh",
                    "备份 · Enter 恢复 · r 刷新",
                ),
                true,
            ))
            .highlight_style(Style::default().bg(Color::DarkGray))
            .highlight_symbol("› ");
        frame.render_stateful_widget(
            list,
            area,
            &mut ListState::default().with_selected(if self.backups.is_empty() {
                None
            } else {
                Some(self.selected)
            }),
        );
        if self.backups.is_empty() {
            frame.render_widget(
                Paragraph::new(self.tr("No backups for this file.", "此文件暂无备份。")),
                Rect {
                    x: area.x + 2,
                    y: area.y + 2,
                    width: area.width.saturating_sub(4),
                    height: 1,
                },
            );
        }
    }

    fn draw_settings(&self, frame: &mut Frame, area: Rect) {
        let columns = if area.width >= 90 {
            Layout::default()
                .direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
                .split(area)
                .to_vec()
        } else {
            vec![area]
        };
        let rows = vec![
            format!("{}: {}", self.tr("Language", "语言"), self.options.language),
            format!(
                "{}: {}",
                self.tr("Working directory", "工作目录"),
                self.options
                    .cwd
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_else(|| self.tr("automatic", "自动").into())
            ),
            format!(
                "CODEX_HOME: {}",
                self.options
                    .codex_home
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_else(|| self.tr("automatic", "自动").into())
            ),
            format!(
                "{}: {}",
                self.tr("Analysis Profile", "分析 Profile"),
                self.options
                    .profile
                    .as_deref()
                    .unwrap_or(self.tr("none", "无"))
            ),
            self.tr("Check schema update", "检查 Schema 更新").into(),
            self.tr("Update schema", "更新 Schema").into(),
            self.tr("Import schema JSON", "导入 Schema JSON").into(),
            self.tr("Reset to bundled schema", "恢复内置 Schema").into(),
            self.tr("Read Codex features snapshot", "读取 Codex 功能状态快照")
                .into(),
        ];
        let list = List::new(rows)
            .block(self.panel(
                self.tr(
                    "Settings · Enter changes selected option",
                    "设置 · Enter 修改选项",
                ),
                true,
            ))
            .highlight_style(Style::default().bg(Color::DarkGray))
            .highlight_symbol("› ");
        frame.render_stateful_widget(
            list,
            columns[0],
            &mut ListState::default().with_selected(Some(self.selected)),
        );
        if let Some(area) = columns.get(1) {
            frame.render_widget(
                Paragraph::new(pretty(&self.metadata))
                    .wrap(Wrap { trim: false })
                    .block(self.panel(self.tr("Schema provenance", "Schema 来源"), false)),
                *area,
            );
        }
    }

    fn draw_modal(&self, frame: &mut Frame, area: Rect) {
        let Some(modal) = &self.modal else {
            return;
        };
        let width = area.width.saturating_sub(4).min(110);
        let height = match modal {
            Modal::Confirm { .. } => 9.min(area.height),
            _ => area.height.saturating_sub(4).max(5),
        };
        let popup = Rect {
            x: area.x + (area.width - width) / 2,
            y: area.y + (area.height - height) / 2,
            width,
            height,
        };
        frame.render_widget(Clear, popup);
        match modal {
            Modal::Text {
                title,
                body,
                scroll,
            } => {
                frame.render_widget(
                    Paragraph::new(body.as_str())
                        .wrap(Wrap { trim: false })
                        .scroll((*scroll, 0))
                        .block(self.panel(format!("{title} · Esc"), true)),
                    popup,
                );
            }
            Modal::Confirm { action } => {
                let action_text = match action {
                    Pending::Quit => self.tr("Quit", "退出"),
                    Pending::Open(_) => self.tr("Switch file", "切换文件"),
                    Pending::Restore(_) => self.tr("Restore backup", "恢复备份"),
                };
                let body = if self.dirty() {
                    self.tr("This file has unsaved changes.\n\ns: Save, then continue\nd: Discard draft, then continue\nEsc / c: Cancel", "此文件有未保存更改。\n\ns：保存后继续\nd：丢弃草稿后继续\nEsc / c：取消")
                } else {
                    self.tr("Restore the selected backup?\nThe current file will be backed up first.\n\nEnter / y: Restore    Esc: Cancel", "恢复所选备份？\n恢复前会先备份当前文件。\n\nEnter / y：恢复    Esc：取消")
                };
                frame.render_widget(
                    Paragraph::new(body)
                        .wrap(Wrap { trim: false })
                        .block(self.panel(action_text, true)),
                    popup,
                );
            }
            Modal::Menu {
                title,
                items,
                selected,
            } => {
                let list = List::new(items.iter().map(|(label, _)| ListItem::new(label.as_str())))
                    .block(self.panel(format!("{title} · Enter / Esc"), true))
                    .highlight_style(Style::default().bg(Color::DarkGray))
                    .highlight_symbol("› ");
                frame.render_stateful_widget(
                    list,
                    popup,
                    &mut ListState::default().with_selected(if items.is_empty() {
                        None
                    } else {
                        Some(*selected)
                    }),
                );
            }
            Modal::Input { title, input, .. } => {
                let inside = self.panel(title.as_str(), true).inner(popup);
                let body_height = inside.height.saturating_sub(2);
                let before = &input.value[..input.cursor];
                let row = before
                    .chars()
                    .filter(|character| *character == '\n')
                    .count();
                let last_line = before.rsplit('\n').next().unwrap_or_default();
                let column = Line::from(last_line).width();
                let row_offset = row.saturating_sub(usize::from(body_height.saturating_sub(1)));
                let column_offset =
                    column.saturating_sub(usize::from(inside.width.saturating_sub(1)));
                frame.render_widget(self.panel(title.as_str(), true), popup);
                frame.render_widget(
                    Paragraph::new(input.value.as_str()).scroll((
                        row_offset.min(u16::MAX as usize) as u16,
                        column_offset.min(u16::MAX as usize) as u16,
                    )),
                    Rect {
                        height: body_height,
                        ..inside
                    },
                );
                frame.render_widget(
                    Paragraph::new(self.tr(
                        "Ctrl+S apply · Esc cancel · Ctrl+U clear",
                        "Ctrl+S 应用 · Esc 取消 · Ctrl+U 清空",
                    ))
                    .style(Style::default().fg(Color::Cyan)),
                    Rect {
                        y: inside.y + body_height,
                        height: 1,
                        ..inside
                    },
                );
                frame.render_widget(
                    Paragraph::new(self.status.as_str()).style(Style::default().fg(Color::Yellow)),
                    Rect {
                        y: inside.y + body_height + 1,
                        height: 1,
                        ..inside
                    },
                );
                if body_height > 0 && inside.width > 0 {
                    frame.set_cursor_position((
                        inside.x + (column - column_offset) as u16,
                        inside.y + (row - row_offset) as u16,
                    ));
                }
            }
        }
    }
}
