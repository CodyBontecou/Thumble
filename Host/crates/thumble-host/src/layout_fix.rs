use super::*;
use crate::draft_operation::{
    ConfigurationOperation, ConfigurationVariant, LayoutRepairCanvas, LayoutRepairKind,
    LayoutRepairTarget,
};
use serde_json::{Map, Value};
use std::cmp::Ordering;
use thumble_protocol::KeypadElementID;

// Starter appearance anchors only. Missing elements are never synthesized.
const BUILTINS: [&str; 10] = [
    "00000000-0000-0000-0000-000000000101", "00000000-0000-0000-0000-000000000102",
    "00000000-0000-0000-0000-000000000103", "00000000-0000-0000-0000-000000000104",
    "00000000-0000-0000-0000-000000000105", "00000000-0000-0000-0000-000000000106",
    "00000000-0000-0000-0000-000000000107", "00000000-0000-0000-0000-000000000108",
    "00000000-0000-0000-0000-000000000109", "00000000-0000-0000-0000-00000000010A",
];
const HIT_OUTSET: f64 = 10.0;

pub(super) fn constrained_layout_fix_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    let ConfigurationOperation::CustomizationFix {
        profile_id,
        variant,
        target,
        canvas,
        include_locked,
    } = operation
    else {
        return false;
    };
    if !customization_operation_delta(before, after, profile_id, *variant) {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let source_key = match variant {
        ConfigurationVariant::Primary => "customization",
        ConfigurationVariant::Landscape => "landscapeCustomization",
        ConfigurationVariant::Portrait => "portraitCustomization",
    };
    let Some(mut expected) = before_profile
        .get(source_key)
        .or_else(|| before_profile.get("customization"))
        .and_then(Value::as_object)
        .cloned()
    else {
        return false;
    };
    if *variant != ConfigurationVariant::Primary {
        if let Some(color_scheme) = before_profile
            .get("customization")
            .and_then(|value| value.get("colorSchemePreference"))
        {
            expected.insert("colorSchemePreference".to_owned(), color_scheme.clone());
        }
    }
    let Some(canvas_size) = repair_canvas_size(&expected, canvas) else {
        return false;
    };
    let mut engine = RepairEngine::new(expected, canvas_size, !*include_locked);
    if !engine.apply_target(target) {
        return false;
    }
    expected = engine.customization;
    if *variant != ConfigurationVariant::Primary {
        correct_customization_frame_orientation(&mut expected, *variant);
    }
    let Some(mut actual) = after_profile.get("customization").and_then(Value::as_object).cloned() else { return false; };
    if !materialize_declared_custom_mirrors(&mut actual) { return false; }
    layout_fix_semantically_equal(&Value::Object(actual), &Value::Object(expected), None)
}

/// Reconstruct alignment/distribution from the declared controls' resolved geometry,
/// then compare the entire logical customization, including untouched siblings.
pub(super) fn constrained_element_arrangement_delta(
    source: &Map<String, Value>,
    result: &Map<String, Value>,
    operation: &ConfigurationOperation,
) -> bool {
    use crate::draft_operation::{ControlAlignment as A, ControlDistribution as D};
    let ids = match operation {
        ConfigurationOperation::ElementAlign { element_ids, .. }
        | ConfigurationOperation::ElementDistribute { element_ids, .. } => element_ids,
        _ => return false,
    };
    let Some(requested) = ids.iter().map(|id| thumble_protocol::KeypadElementID::parse(id))
        .collect::<Option<std::collections::HashSet<_>>>() else { return false; };
    let Some(canvas) = customization_canvas_size(source) else { return false; };
    let mut expected = source.clone();
    let mut actual = result.clone();
    if !materialize_declared_custom_mirrors(&mut expected)
        || !materialize_declared_custom_mirrors(&mut actual) { return false; }
    let Some(controls) = resolved_repair_controls(&expected, canvas.0, canvas.1) else { return false; };
    let mut controls = controls.into_iter().filter(|control| {
        !control.locked && control.element_id.is_some_and(|id| requested.contains(&id))
    }).collect::<Vec<_>>();
    let mut positions = Vec::new();
    match operation {
        ConfigurationOperation::ElementAlign { alignment, .. } => {
            if controls.len() < 2 { return false; }
            let left = controls.iter().map(|c| c.frame().min_x()).fold(f64::INFINITY, f64::min);
            let right = controls.iter().map(|c| c.frame().max_x()).fold(f64::NEG_INFINITY, f64::max);
            let top = controls.iter().map(|c| c.frame().min_y()).fold(f64::INFINITY, f64::min);
            let bottom = controls.iter().map(|c| c.frame().max_y()).fold(f64::NEG_INFINITY, f64::max);
            for control in &controls {
                let (x, y) = match alignment {
                    A::Left => (left + control.width / 2.0, control.center_y),
                    A::Right => (right - control.width / 2.0, control.center_y),
                    A::HorizontalCenters => ((left + right) / 2.0, control.center_y),
                    A::Top => (control.center_x, top + control.height / 2.0),
                    A::Bottom => (control.center_x, bottom - control.height / 2.0),
                    A::VerticalCenters => (control.center_x, (top + bottom) / 2.0),
                };
                positions.push((control.identity.clone(), normalized_position(x, y, control.width, control.height, canvas)));
            }
        }
        ConfigurationOperation::ElementDistribute { distribution, .. } => {
            if controls.len() < 3 { return false; }
            let horizontal = matches!(distribution, D::HorizontalCenters | D::HorizontalSpacing);
            let centers = matches!(distribution, D::HorizontalCenters | D::VerticalCenters);
            let coordinate = |c: &RepairControl| if horizontal { c.center_x } else { c.center_y };
            let dimension = |c: &RepairControl| if horizontal { c.width } else { c.height };
            controls.sort_by(|a, b| coordinate(a).total_cmp(&coordinate(b)));
            let first = &controls[0];
            let last = &controls[controls.len() - 1];
            let start = coordinate(first);
            let end = coordinate(last);
            let step = (end - start) / (controls.len() - 1) as f64;
            let span = (end + dimension(last) / 2.0) - (start - dimension(first) / 2.0);
            let spacing = (span - controls.iter().map(dimension).sum::<f64>()) / (controls.len() - 1) as f64;
            let mut trailing = start + dimension(first) / 2.0;
            for (index, control) in controls.iter().enumerate().skip(1).take(controls.len() - 2) {
                let target = if centers { start + index as f64 * step } else { trailing + spacing + dimension(control) / 2.0 };
                trailing = target + dimension(control) / 2.0;
                let (x, y) = if horizontal { (target, control.center_y) } else { (control.center_x, target) };
                positions.push((control.identity.clone(), normalized_position(x, y, control.width, control.height, canvas)));
            }
        }
        _ => return false,
    }
    for (identity, (x, y)) in positions {
        let Some((actual_x, actual_y)) = group_child_position(&actual, &identity) else { return false; };
        if (x - actual_x).abs() > 1e-12 || (y - actual_y).abs() > 1e-12
            || !set_group_child_position(&mut expected, &identity, actual_x, actual_y) { return false; }
    }
    let variant = match operation {
        ConfigurationOperation::ElementAlign { variant, .. }
        | ConfigurationOperation::ElementDistribute { variant, .. } => *variant,
        _ => return false,
    };
    correct_customization_frame_orientation(&mut expected, variant);
    layout_fix_semantically_equal(&Value::Object(actual), &Value::Object(expected), None)
}

fn repair_canvas_size(
    customization: &Map<String, Value>,
    canvas: &LayoutRepairCanvas,
) -> Option<(f64, f64)> {
    match canvas {
        LayoutRepairCanvas::Stored {} => customization_canvas_size(customization),
        LayoutRepairCanvas::Frame { frame_id } => nudge_canvas_size(frame_id),
        LayoutRepairCanvas::Size { width, height } => (width.is_finite()
            && height.is_finite()
            && (240.0..=1_800.0).contains(width)
            && (240.0..=1_800.0).contains(height))
        .then_some((*width, *height)),
    }
}

fn layout_fix_semantically_equal(actual: &Value, expected: &Value, field: Option<&str>) -> bool {
    match (actual, expected) {
        (Value::Number(actual), Value::Number(expected)) => {
            let (Some(actual), Some(expected)) = (actual.as_f64(), expected.as_f64()) else {
                return actual == expected;
            };
            if matches!(
                field,
                Some("centerX" | "centerY" | "widthScale" | "heightScale")
            ) {
                actual.is_finite() && expected.is_finite() && (actual - expected).abs() <= 1e-12
            } else {
                actual == expected
            }
        }
        (Value::Array(actual), Value::Array(expected)) => {
            actual.len() == expected.len()
                && actual.iter().zip(expected).all(|(actual, expected)| {
                    layout_fix_semantically_equal(actual, expected, field)
                })
        }
        (Value::Object(actual), Value::Object(expected)) => {
            actual.len() == expected.len()
                && actual.iter().all(|(key, actual)| {
                    expected.get(key).is_some_and(|expected| {
                        layout_fix_semantically_equal(actual, expected, Some(key))
                    })
                })
        }
        _ => actual == expected,
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Rect {
    fn min_x(self) -> f64 {
        self.x
    }
    fn max_x(self) -> f64 {
        self.x + self.width
    }
    fn min_y(self) -> f64 {
        self.y
    }
    fn max_y(self) -> f64 {
        self.y + self.height
    }
    fn mid_x(self) -> f64 {
        self.x + self.width / 2.0
    }
    fn mid_y(self) -> f64 {
        self.y + self.height / 2.0
    }
    fn area(self) -> f64 {
        self.width * self.height
    }
    fn offset(self, dx: f64, dy: f64) -> Self {
        Self {
            x: self.x + dx,
            y: self.y + dy,
            ..self
        }
    }
    fn union(self, other: Self) -> Self {
        let x = self.min_x().min(other.min_x());
        let y = self.min_y().min(other.min_y());
        Self {
            x,
            y,
            width: self.max_x().max(other.max_x()) - x,
            height: self.max_y().max(other.max_y()) - y,
        }
    }
    fn intersection(self, other: Self) -> Option<Self> {
        let x = self.min_x().max(other.min_x());
        let y = self.min_y().max(other.min_y());
        let max_x = self.max_x().min(other.max_x());
        let max_y = self.max_y().min(other.max_y());
        let width = max_x - x;
        let height = max_y - y;
        (width > 0.5 && height > 0.5).then_some(Self {
            x,
            y,
            width,
            height,
        })
    }
    fn contains(self, other: Self) -> bool {
        other.min_x() >= self.min_x()
            && other.max_x() <= self.max_x()
            && other.min_y() >= self.min_y()
            && other.max_y() <= self.max_y()
    }
}

#[derive(Clone, Debug)]
struct RepairControl {
    identity: String,
    stable_id: String,
    element_id: Option<thumble_protocol::KeypadElementID>,
    visual_role: Option<String>,
    label: String,
    kind: String,
    center_x: f64,
    center_y: f64,
    width: f64,
    height: f64,
    locked: bool,
    z_index: i64,
    hit_insets: Option<(f64, f64, f64, f64)>,
    joystick_visual_style: String,
}

impl RepairControl {
    fn frame(&self) -> Rect {
        Rect {
            x: self.center_x - self.width / 2.0,
            y: self.center_y - self.height / 2.0,
            width: self.width,
            height: self.height,
        }
    }
    fn is_decoration(&self) -> bool {
        matches!(self.kind.as_str(), "decoration" | "text")
    }
    fn is_joystick(&self) -> bool {
        self.kind == "joystick"
    }
    fn is_trigger(&self) -> bool {
        self.kind == "trigger"
    }
    fn is_trackpad(&self) -> bool {
        self.kind == "trackpad"
    }
    fn hit_frame(&self) -> Rect {
        let frame = self.frame();
        if let Some((top, leading, bottom, trailing)) = self.hit_insets {
            return Rect {
                x: frame.x - leading,
                y: frame.y - top,
                width: frame.width + leading + trailing,
                height: frame.height + top + bottom,
            };
        }
        if self.is_joystick() {
            let visual_side = self.width.min(self.height);
            let hit_side = if self.joystick_visual_style == "thumbstick" {
                44.0_f64.max(visual_side)
            } else {
                (visual_side + HIT_OUTSET * 2.0).max(visual_side)
            };
            return Rect {
                x: self.center_x - hit_side / 2.0,
                y: self.center_y - hit_side / 2.0,
                width: hit_side,
                height: hit_side,
            };
        }
        Rect {
            x: frame.x - HIT_OUTSET,
            y: frame.y - HIT_OUTSET,
            width: frame.width + HIT_OUTSET * 2.0,
            height: frame.height + HIT_OUTSET * 2.0,
        }
    }
    fn touch_priority(&self) -> i32 {
        if self.is_trigger() {
            0
        } else if self.is_joystick() {
            1
        } else if self.is_trackpad() {
            3
        } else {
            2
        }
    }
}

#[derive(Clone, Debug)]
struct RepairIssue {
    code: &'static str,
    controls: Vec<String>,
    severity: u8,
}

impl RepairIssue {
    fn suggested_repair(&self) -> Option<LayoutRepairKind> {
        Some(match self.code {
            "no-visible-controls" => LayoutRepairKind::ShowDefaultControls,
            "control-overlap" => LayoutRepairKind::ResolveOverlap,
            "expanded-hit-overlap"
            | "hit-region-z-order-ambiguous"
            | "hit-region-z-order-mismatch" => LayoutRepairKind::SeparateExpandedHitTargets,
            "layout-displacement" | "edge-hugging-control" => LayoutRepairKind::MoveInsideSafeArea,
            "small-control" => LayoutRepairKind::MinimumTouchTarget,
            "primary-control-too-high"
            | "primary-control-too-central"
            | "primary-control-out-of-reach"
            | "portrait-primary-action-distribution"
            | "portrait-dead-space" => LayoutRepairKind::ErgonomicAutoArrange,
            "underused-bottom-space" | "low-vertical-coverage" | "low-horizontal-coverage" => {
                LayoutRepairKind::AutoArrange
            }
            _ => return None,
        })
    }
}

struct RepairEngine {
    customization: Map<String, Value>,
    canvas: (f64, f64),
    respecting_locks: bool,
    valid_declarations: bool,
}

impl RepairEngine {
    fn new(mut customization: Map<String, Value>, canvas: (f64, f64), respecting_locks: bool) -> Self {
        let valid_declarations = materialize_declared_custom_mirrors(&mut customization);
        Self {
            customization,
            canvas,
            respecting_locks,
            valid_declarations,
        }
    }

    fn apply_target(&mut self, target: &LayoutRepairTarget) -> bool {
        if !self.valid_declarations {
            return false;
        }
        match target {
            LayoutRepairTarget::Repair { repair } => {
                let changed = self.apply_repair(*repair, None);
                if changed {
                    canonicalize_button_customization_order(&mut self.customization);
                }
                true
            }
            LayoutRepairTarget::All {} => {
                let mut changed_any = false;
                for _ in 0..3 {
                    let mut issues = self.issues();
                    issues.sort_by_key(|issue| issue_priority(issue.code));
                    let mut changed = false;
                    let mut auto_arranged = false;
                    for issue in issues {
                        let Some(repair) = issue.suggested_repair() else {
                            continue;
                        };
                        if repair == LayoutRepairKind::AutoArrange {
                            if auto_arranged {
                                continue;
                            }
                            auto_arranged = true;
                        }
                        let requested = (repair != LayoutRepairKind::AutoArrange)
                            .then_some(issue.controls.as_slice());
                        changed |= self.apply_repair(repair, requested);
                    }
                    changed_any |= changed;
                    if !changed {
                        break;
                    }
                }
                if changed_any {
                    canonicalize_button_customization_order(&mut self.customization);
                }
                true
            }
        }
    }

    fn controls(&self) -> Option<Vec<RepairControl>> {
        resolved_repair_controls(&self.customization, self.canvas.0, self.canvas.1)
    }

    fn issues(&self) -> Vec<RepairIssue> {
        let Some(controls) = self.controls() else {
            return Vec::new();
        };
        let interactive = controls
            .iter()
            .filter(|control| !control.is_decoration())
            .cloned()
            .collect::<Vec<_>>();
        let mut issues = Vec::new();
        if interactive.is_empty() {
            issues.push(RepairIssue {
                code: "no-visible-controls",
                controls: Vec::new(),
                severity: 0,
            });
        }
        let freeform = uses_freeform_layout(&self.customization);
        if freeform {
            issues.extend(overlap_issues(&interactive));
            issues.extend(size_issues(&interactive));
            issues.extend(edge_issues(&interactive, self.canvas));
            issues.extend(utilization_issues(&interactive, self.canvas));
            issues.extend(ergonomic_issues(
                &interactive,
                self.canvas,
                reach_mode(&self.customization),
            ));
            if self.canvas.1 > self.canvas.0 {
                issues.extend(portrait_issues(
                    &interactive,
                    self.canvas,
                    reach_mode(&self.customization),
                ));
            }
        }
        issues.sort_by(issue_order);
        issues
    }

    fn requested_controls(&self, requested: Option<&[String]>) -> Option<Vec<RepairControl>> {
        let controls = self.controls()?;
        let requested = requested.unwrap_or_default();
        Some(
            controls
                .into_iter()
                .filter(|control| {
                    requested.is_empty() || requested.iter().any(|id| id == &control.identity)
                })
                .collect(),
        )
    }

    fn apply_repair(&mut self, repair: LayoutRepairKind, requested: Option<&[String]>) -> bool {
        match repair {
            LayoutRepairKind::ShowDefaultControls => self.show_default_controls(),
            LayoutRepairKind::MinimumTouchTarget => self.minimum_touch_target(requested),
            LayoutRepairKind::MoveInsideSafeArea => self.move_inside_safe_area(requested),
            LayoutRepairKind::ResolveOverlap => self.resolve_overlap(requested),
            LayoutRepairKind::AutoArrange => self.auto_arrange(requested),
            LayoutRepairKind::SeparateExpandedHitTargets => {
                self.separate_expanded_hit_targets(requested)
            }
            LayoutRepairKind::ErgonomicAutoArrange => self.ergonomic_auto_arrange(requested),
        }
    }

    fn show_default_controls(&mut self) -> bool {
        let Some(elements) = self.customization.get("elements").and_then(Value::as_array) else { return false; };
        let Some(existing) = elements.iter().map(|element| element.get("id").and_then(Value::as_str).and_then(KeypadElementID::parse))
            .collect::<Option<std::collections::BTreeSet<_>>>() else { return false; };
        let missing_count = BUILTINS.iter().filter(|id| !existing.contains(&KeypadElementID::parse(id).unwrap())).count();
        let mut changed = false;
        if existing.len() + missing_count <= 128 {
            // Explicit authoring requested by this repair, not an import or runtime fallback.
            let starter = thumble_core::minimal_default_customization();
            for prototype in starter["elements"].as_array().unwrap() {
                let id = prototype["id"].as_str().unwrap();
                if existing.contains(&KeypadElementID::parse(id).unwrap()) { continue; }
                let mut element = prototype.clone();
                element["label"] = Value::String(builtin_visual_label(&self.customization, id));
                let mut layout = default_button_layout();
                layout.insert("centerX".to_owned(), Value::from(0.5));
                layout.insert("centerY".to_owned(), Value::from(0.5));
                layout.insert("shape".to_owned(), Value::String("rounded_rectangle".to_owned()));
                element["layout"] = Value::Object(layout);
                self.customization.get_mut("elements").and_then(Value::as_array_mut).unwrap().push(element);
                changed = true;
            }
        }
        for button in BUILTINS {
            if !self.customization.get("elements").and_then(Value::as_array).unwrap().iter().any(|element| {
                element.get("id").and_then(Value::as_str).is_some_and(|id| id.eq_ignore_ascii_case(button))
                    && element.get("kind").and_then(Value::as_str).unwrap_or("button") == "button"
            }) { continue; }
            let Some(layout) = builtin_layout(&self.customization, button) else { return false; };
            if layout.get("isHidden").and_then(Value::as_bool).unwrap_or(false)
                || !existing.contains(&KeypadElementID::parse(button).unwrap())
            {
                if !set_builtin_layout_state(&mut self.customization, button, "isHidden", false) { return false; }
                changed = true;
            }
        }
        changed
    }

    fn minimum_touch_target(&mut self, requested: Option<&[String]>) -> bool {
        let Some(controls) = self.requested_controls(requested) else {
            return false;
        };
        let mut changed = false;
        for control in controls {
            if control.is_decoration() || (self.respecting_locks && control.locked) {
                continue;
            }
            let target_width = self.canvas.0.min(44.0_f64.max(control.width));
            let target_height = self.canvas.1.min(44.0_f64.max(control.height));
            if target_width <= control.width + 0.001 && target_height <= control.height + 0.001 {
                continue;
            }
            let Some(mut layout) = control_layout(&self.customization, &control.identity) else {
                return false;
            };
            let width_scale = layout
                .get("widthScale")
                .and_then(Value::as_f64)
                .unwrap_or(1.0)
                * target_width
                / control.width.max(0.001);
            let height_scale = layout
                .get("heightScale")
                .and_then(Value::as_f64)
                .unwrap_or(1.0)
                * target_height
                / control.height.max(0.001);
            layout.insert(
                "widthScale".to_owned(),
                Value::from(width_scale.clamp(0.001, 12.0)),
            );
            layout.insert(
                "heightScale".to_owned(),
                Value::from(height_scale.clamp(0.001, 12.0)),
            );
            let (x, y) = normalized_position(
                control.center_x,
                control.center_y,
                target_width,
                target_height,
                self.canvas,
            );
            layout.insert("centerX".to_owned(), Value::from(x));
            layout.insert("centerY".to_owned(), Value::from(y));
            if !replace_control_layout(&mut self.customization, &control.identity, layout) {
                return false;
            }
            changed = true;
        }
        changed
    }

    fn move_inside_safe_area(&mut self, requested: Option<&[String]>) -> bool {
        let Some(controls) = self.requested_controls(requested) else {
            return false;
        };
        let inset = (self.canvas.0.min(self.canvas.1) * 0.03).clamp(2.0, 12.0);
        let mut changed = false;
        for control in controls {
            if control.is_decoration() || (self.respecting_locks && control.locked) {
                continue;
            }
            let x = safe_center_coordinate(control.center_x, control.width, self.canvas.0, inset);
            let y = safe_center_coordinate(control.center_y, control.height, self.canvas.1, inset);
            if distance(x, y, control.center_x, control.center_y) <= 0.001 {
                continue;
            }
            if !set_control_position(
                &mut self.customization,
                &control.identity,
                x / self.canvas.0.max(1.0),
                y / self.canvas.1.max(1.0),
            ) {
                return false;
            }
            changed = true;
        }
        changed
    }

    fn resolve_overlap(&mut self, requested: Option<&[String]>) -> bool {
        let Some(all_controls) = self.controls() else {
            return false;
        };
        let all_controls = all_controls
            .into_iter()
            .filter(|control| !control.is_decoration())
            .collect::<Vec<_>>();
        let requested_ids = requested.unwrap_or_default();
        let candidates = all_controls
            .iter()
            .filter(|control| {
                requested_ids.is_empty() || requested_ids.iter().any(|id| id == &control.identity)
            })
            .cloned()
            .collect::<Vec<_>>();
        let has_locked = self.respecting_locks && candidates.iter().any(|control| control.locked);
        let mut stationary = all_controls
            .iter()
            .filter(|control| {
                !candidates
                    .iter()
                    .any(|candidate| candidate.identity == control.identity)
                    || (self.respecting_locks && control.locked)
            })
            .map(RepairControl::frame)
            .collect::<Vec<_>>();
        let mut changed = false;
        for (index, control) in candidates.iter().enumerate() {
            if self.respecting_locks && control.locked {
                continue;
            }
            if index == 0 && requested_ids.len() > 1 && !has_locked {
                stationary.push(control.frame());
                continue;
            }
            let Some(frame) = non_overlapping_frame(control.frame(), &stationary, self.canvas)
            else {
                stationary.push(control.frame());
                continue;
            };
            stationary.push(frame);
            if distance(
                frame.mid_x(),
                frame.mid_y(),
                control.center_x,
                control.center_y,
            ) <= 0.001
            {
                continue;
            }
            if !set_control_position(
                &mut self.customization,
                &control.identity,
                frame.mid_x() / self.canvas.0.max(1.0),
                frame.mid_y() / self.canvas.1.max(1.0),
            ) {
                return false;
            }
            changed = true;
        }
        changed
    }

    fn auto_arrange(&mut self, requested: Option<&[String]>) -> bool {
        let Some(all_controls) = self.controls() else {
            return false;
        };
        let all_controls = all_controls
            .into_iter()
            .filter(|control| !control.is_decoration())
            .collect::<Vec<_>>();
        let requested_ids = requested.unwrap_or_default();
        let candidates = all_controls
            .iter()
            .filter(|control| {
                requested_ids.is_empty() || requested_ids.iter().any(|id| id == &control.identity)
            })
            .cloned()
            .collect::<Vec<_>>();
        let unlocked = candidates
            .into_iter()
            .filter(|control| !self.respecting_locks || !control.locked)
            .collect::<Vec<_>>();
        let Some(source_bounds) = union_frames(unlocked.iter().map(RepairControl::frame)) else {
            return false;
        };
        if unlocked.is_empty() {
            return false;
        }
        let padding = (self.canvas.0.min(self.canvas.1) * 0.06).clamp(10.0, 24.0);
        let mut placed = all_controls
            .iter()
            .filter(|control| {
                !unlocked
                    .iter()
                    .any(|candidate| candidate.identity == control.identity)
            })
            .map(RepairControl::frame)
            .collect::<Vec<_>>();
        let mut changed = false;
        for (index, control) in unlocked.iter().enumerate() {
            let x_progress = if source_bounds.width > 1.0 {
                (control.center_x - source_bounds.min_x()) / source_bounds.width
            } else {
                (index + 1) as f64 / (unlocked.len() + 1) as f64
            };
            let y_progress = if source_bounds.height > 1.0 {
                (control.center_y - source_bounds.min_y()) / source_bounds.height
            } else {
                (index % 2 + 1) as f64 / 3.0
            };
            let min_x = padding + control.width / 2.0;
            let max_x = min_x.max(self.canvas.0 - padding - control.width / 2.0);
            let min_y = padding + control.height / 2.0;
            let max_y = min_y.max(self.canvas.1 - padding - control.height / 2.0);
            let proposed_x = min_x + x_progress.clamp(0.0, 1.0) * (max_x - min_x);
            let proposed_y = min_y + y_progress.clamp(0.0, 1.0) * (max_y - min_y);
            let proposed = Rect {
                x: proposed_x - control.width / 2.0,
                y: proposed_y - control.height / 2.0,
                width: control.width,
                height: control.height,
            };
            let arranged =
                non_overlapping_frame(proposed, &placed, self.canvas).unwrap_or(proposed);
            placed.push(arranged);
            if distance(
                arranged.mid_x(),
                arranged.mid_y(),
                control.center_x,
                control.center_y,
            ) <= 0.001
            {
                continue;
            }
            if !set_control_position(
                &mut self.customization,
                &control.identity,
                arranged.mid_x() / self.canvas.0.max(1.0),
                arranged.mid_y() / self.canvas.1.max(1.0),
            ) {
                return false;
            }
            changed = true;
        }
        changed
    }

    fn separate_expanded_hit_targets(&mut self, requested: Option<&[String]>) -> bool {
        let Some(controls) = self.controls() else {
            return false;
        };
        let controls = controls
            .into_iter()
            .filter(|control| !control.is_decoration())
            .collect::<Vec<_>>();
        let requested = requested.unwrap_or_default();
        let mut movable = controls
            .iter()
            .filter(|control| {
                (requested.is_empty() || requested.iter().any(|id| id == &control.identity))
                    && (!self.respecting_locks || !control.locked)
            })
            .cloned()
            .collect::<Vec<_>>();
        movable.sort_by(|left, right| left.stable_id.cmp(&right.stable_id));
        if movable.is_empty() {
            return false;
        }
        let movable_ids = movable
            .iter()
            .map(|control| control.identity.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        let mut fixed = controls
            .iter()
            .filter(|control| !movable_ids.contains(control.identity.as_str()))
            .cloned()
            .collect::<Vec<_>>();
        fixed.sort_by(|left, right| left.stable_id.cmp(&right.stable_id));
        let mut occupied = fixed
            .iter()
            .map(RepairControl::hit_frame)
            .collect::<Vec<_>>();
        let mut changes = Vec::new();
        for control in &movable {
            let candidate = nearest_separated_frame(control, &occupied, self.canvas);
            occupied.push(control.hit_frame().offset(
                candidate.mid_x() - control.center_x,
                candidate.mid_y() - control.center_y,
            ));
            if distance(
                candidate.mid_x(),
                candidate.mid_y(),
                control.center_x,
                control.center_y,
            ) > 0.01
            {
                let position = normalized_position(
                    candidate.mid_x(),
                    candidate.mid_y(),
                    control.width,
                    control.height,
                    self.canvas,
                );
                changes.push((control.identity.clone(), position));
            }
        }
        for (identity, (x, y)) in &changes {
            if !set_control_position(&mut self.customization, identity, *x, *y) {
                return false;
            }
        }
        !changes.is_empty()
    }

    fn ergonomic_auto_arrange(&mut self, requested: Option<&[String]>) -> bool {
        let Some(controls) = self.requested_controls(requested) else {
            return false;
        };
        let mut movement = controls
            .iter()
            .filter(|control| {
                ergonomic_role(control) == ErgonomicRole::Movement
                    && (!self.respecting_locks || !control.locked)
            })
            .cloned()
            .collect::<Vec<_>>();
        let mut actions = controls
            .iter()
            .filter(|control| {
                ergonomic_role(control) == ErgonomicRole::Action
                    && (!self.respecting_locks || !control.locked)
            })
            .cloned()
            .collect::<Vec<_>>();
        movement.sort_by(ergonomic_control_order);
        actions.sort_by(ergonomic_control_order);
        if movement.is_empty() && actions.is_empty() {
            return false;
        }
        let portrait = self.canvas.1 > self.canvas.0;
        let mode = reach_mode(&self.customization);
        let mut positions = Vec::new();
        match mode {
            ReachMode::TwoHanded => {
                positions.extend(cluster_positions(
                    &movement,
                    (
                        self.canvas.0 * if portrait { 0.27 } else { 0.18 },
                        self.canvas.1 * if portrait { 0.76 } else { 0.68 },
                    ),
                    true,
                    self.canvas,
                ));
                positions.extend(cluster_positions(
                    &actions,
                    (
                        self.canvas.0 * if portrait { 0.73 } else { 0.82 },
                        self.canvas.1 * if portrait { 0.76 } else { 0.68 },
                    ),
                    false,
                    self.canvas,
                ));
            }
            ReachMode::OneHandedLeft | ReachMode::OneHandedRight => {
                let mut combined = movement;
                combined.extend(actions);
                combined.sort_by(ergonomic_control_order);
                let left = mode == ReachMode::OneHandedLeft;
                let anchor_x = if left {
                    if portrait {
                        0.27
                    } else {
                        0.25
                    }
                } else if portrait {
                    0.73
                } else {
                    0.75
                };
                positions.extend(one_handed_positions(
                    &combined,
                    (
                        self.canvas.0 * anchor_x,
                        self.canvas.1 * if portrait { 0.86 } else { 0.82 },
                    ),
                    self.canvas,
                ));
            }
        }
        let mut changed = false;
        let affected = positions
            .iter()
            .map(|(id, _, _)| id.clone())
            .collect::<Vec<_>>();
        for (identity, x, y) in positions {
            let Some(original) = controls.iter().find(|control| control.identity == identity)
            else {
                return false;
            };
            let resolved_x = x * self.canvas.0;
            let resolved_y = y * self.canvas.1;
            if distance(resolved_x, resolved_y, original.center_x, original.center_y) <= 0.01 {
                continue;
            }
            if !set_control_position(&mut self.customization, &identity, x, y) {
                return false;
            }
            changed = true;
        }
        let separated = self.separate_expanded_hit_targets(Some(&affected));
        changed || separated
    }
}

fn resolved_repair_controls(
    customization: &Map<String, Value>,
    canvas_width: f64,
    canvas_height: f64,
) -> Option<Vec<RepairControl>> {
    if canvas_width <= 1.0 || canvas_height <= 1.0 {
        return Some(Vec::new());
    }
    let control_scale = match customization
        .get("controlScale")
        .and_then(Value::as_str)
        .unwrap_or("standard")
    {
        "compact" => 0.86,
        "standard" => 1.0,
        "large" => 1.14,
        _ => return None,
    };
    let layout_mode = customization
        .get("layoutMode")
        .and_then(Value::as_str)
        .unwrap_or("standard");
    let mut controls = Vec::new();
    for button in BUILTINS {
        let Some(element) = customization.get("elements").and_then(Value::as_array).into_iter().flatten()
            .find(|element| element.get("kind").and_then(Value::as_str).unwrap_or("button") == "button"
                && element.get("id").and_then(Value::as_str).is_some_and(|id| id.eq_ignore_ascii_case(button)))
        else { continue; };
        let layout = element.get("layout").and_then(Value::as_object).cloned().or_else(|| builtin_layout(customization, button))?;
        if layout
            .get("isHidden")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            continue;
        }
        let base = builtin_base_size(button, control_scale, canvas_width, canvas_height)?;
        let width = base.0 * normalized_layout_scale(&layout, "widthScale")?;
        let height = base.1 * normalized_layout_scale(&layout, "heightScale")?;
        let default = default_builtin_center(
            button,
            layout_mode,
            width,
            height,
            canvas_width,
            canvas_height,
        )?;
        let normalized_x = normalized_layout_center(&layout, "centerX", default.0)?;
        let normalized_y = normalized_layout_center(&layout, "centerY", default.1)?;
        let (center_x, center_y) = clamped_center(
            normalized_x,
            normalized_y,
            width,
            height,
            (canvas_width, canvas_height),
        );
        controls.push(RepairControl {
            identity: format!("builtin:{button}"),
            stable_id: format!("builtin.{button}"),
            element_id: thumble_protocol::KeypadElementID::parse(button),
            visual_role: element.get("visualRole").and_then(Value::as_str).map(str::to_owned),
            label: builtin_visual_label(customization, button),
            kind: "button".to_owned(),
            center_x,
            center_y,
            width,
            height,
            locked: layout
                .get("isLocationLocked")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            z_index: layout.get("zIndex").and_then(Value::as_i64).unwrap_or(0),
            hit_insets: normalized_hit_insets(&layout)?,
            joystick_visual_style: layout
                .get("joystickVisualStyle")
                .and_then(Value::as_str)
                .unwrap_or("pad")
                .to_owned(),
        });
    }
    for button in customization
        .get("customButtons")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let button = button.as_object()?;
        let id = button.get("id").and_then(Value::as_str)?;
        let canonical_id = Uuid::parse_str(id).ok()?.hyphenated().to_string();
        if customization.get("elements").and_then(Value::as_array).into_iter().flatten().any(|element| {
            element.get("kind").and_then(Value::as_str).unwrap_or("button") == "button"
                && element.get("id").and_then(Value::as_str).is_some_and(|value| value.eq_ignore_ascii_case(id))
                && thumble_protocol::KeypadElementID::parse(id).and_then(|id| id.starter_index()).is_some()
        }) { continue; }
        let layout = button
            .get("layout")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_else(default_custom_layout);
        if layout
            .get("isHidden")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            continue;
        }
        let kind = button
            .get("controlKind")
            .and_then(Value::as_str)
            .unwrap_or("button");
        let base = custom_base_size(kind, control_scale, canvas_width, canvas_height)?;
        let width = base.0 * normalized_layout_scale(&layout, "widthScale")?;
        let height = base.1 * normalized_layout_scale(&layout, "heightScale")?;
        let normalized_x = normalized_layout_center(&layout, "centerX", 0.5)?;
        let normalized_y = normalized_layout_center(&layout, "centerY", 0.5)?;
        let (center_x, center_y) = clamped_center(
            normalized_x,
            normalized_y,
            width,
            height,
            (canvas_width, canvas_height),
        );
        controls.push(RepairControl {
            identity: format!("custom:{canonical_id}"),
            stable_id: format!("custom.{canonical_id}"),
            element_id: thumble_protocol::KeypadElementID::parse(id),
            visual_role: button.get("visualRole").and_then(Value::as_str).map(str::to_owned),
            label: button
                .get("label")
                .and_then(Value::as_str)
                .unwrap_or("Button")
                .to_owned(),
            kind: kind.to_owned(),
            center_x,
            center_y,
            width,
            height,
            locked: layout
                .get("isLocationLocked")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            z_index: layout.get("zIndex").and_then(Value::as_i64).unwrap_or(0),
            hit_insets: normalized_hit_insets(&layout)?,
            joystick_visual_style: layout
                .get("joystickVisualStyle")
                .and_then(Value::as_str)
                .unwrap_or("pad")
                .to_owned(),
        });
    }
    let top_layout = match customization.get("topBarActivationRegion") {
        None | Some(Value::Null) => default_top_bar_layout(),
        Some(value) => value.as_object()?.clone(),
    };
    if !top_layout
        .get("isHidden")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let width = 60.0 * normalized_layout_scale(&top_layout, "widthScale")?;
        let height = 44.0 * normalized_layout_scale(&top_layout, "heightScale")?;
        let x = normalized_layout_center(&top_layout, "centerX", 0.5)?;
        let y = normalized_layout_center(&top_layout, "centerY", 0.115)?;
        let (center_x, center_y) =
            clamped_center(x, y, width, height, (canvas_width, canvas_height));
        controls.push(RepairControl {
            identity: "system:top_bar_activation".to_owned(),
            stable_id: "system.top_bar_activation".to_owned(),
            element_id: None,
            visual_role: Some("system".to_owned()),
            label: "Control Bar".to_owned(),
            kind: "decoration".to_owned(),
            center_x,
            center_y,
            width,
            height,
            locked: top_layout
                .get("isLocationLocked")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            z_index: top_layout
                .get("zIndex")
                .and_then(Value::as_i64)
                .unwrap_or(100),
            hit_insets: normalized_hit_insets(&top_layout)?,
            joystick_visual_style: "pad".to_owned(),
        });
    }
    let order = normalized_layer_order(customization)?;
    let order = order
        .iter()
        .filter_map(layer_identity_key)
        .enumerate()
        .map(|(index, identity)| (identity, index))
        .collect::<std::collections::BTreeMap<_, _>>();
    controls.sort_by(|left, right| {
        left.z_index.cmp(&right.z_index).then_with(|| {
            let left_order = order.get(&left.identity).copied().unwrap_or(usize::MAX);
            let right_order = order.get(&right.identity).copied().unwrap_or(usize::MAX);
            left_order
                .cmp(&right_order)
                .then_with(|| left.stable_id.cmp(&right.stable_id))
        })
    });
    Some(controls)
}

fn normalized_hit_insets(layout: &Map<String, Value>) -> Option<Option<(f64, f64, f64, f64)>> {
    let Some(value) = layout.get("hitInsets") else {
        return Some(None);
    };
    let value = value.as_object()?;
    let component = |key: &str| -> Option<f64> {
        let value = value.get(key).and_then(Value::as_f64).unwrap_or(0.0);
        value.is_finite().then_some(value.clamp(0.0, 96.0))
    };
    Some(Some((
        component("top")?,
        component("leading")?,
        component("bottom")?,
        component("trailing")?,
    )))
}

fn clamped_center(
    normalized_x: f64,
    normalized_y: f64,
    width: f64,
    height: f64,
    canvas: (f64, f64),
) -> (f64, f64) {
    let half_width = (width / 2.0).max(1.0).min(canvas.0 / 2.0);
    let half_height = (height / 2.0).max(1.0).min(canvas.1 / 2.0);
    (
        (normalized_x * canvas.0).clamp(half_width, (canvas.0 - half_width).max(half_width)),
        (normalized_y * canvas.1).clamp(half_height, (canvas.1 - half_height).max(half_height)),
    )
}

fn normalized_position(x: f64, y: f64, width: f64, height: f64, canvas: (f64, f64)) -> (f64, f64) {
    let (x, y) = clamped_center(
        x / canvas.0.max(1.0),
        y / canvas.1.max(1.0),
        width,
        height,
        canvas,
    );
    (x / canvas.0, y / canvas.1)
}

fn safe_center_coordinate(value: f64, length: f64, canvas: f64, inset: f64) -> f64 {
    let lower = inset + length / 2.0;
    let upper = canvas - inset - length / 2.0;
    if lower <= upper {
        value.clamp(lower, upper)
    } else {
        canvas / 2.0
    }
}

fn distance(x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    (x1 - x2).hypot(y1 - y2)
}

fn union_frames(frames: impl Iterator<Item = Rect>) -> Option<Rect> {
    frames.reduce(Rect::union)
}

fn canonicalize_button_customization_order(customization: &mut Map<String, Value>) {
    let Some(values) = customization
        .get_mut("buttonCustomizations")
        .and_then(Value::as_array_mut)
    else {
        return;
    };
    if values.len() % 2 != 0 {
        return;
    }
    let mut pairs = values
        .chunks_exact(2)
        .map(|pair| (pair[0].clone(), pair[1].clone()))
        .collect::<Vec<_>>();
    pairs.sort_by_key(|pair| pair.0.as_str().map(game_button_order).unwrap_or(usize::MAX));
    *values = pairs
        .into_iter()
        .flat_map(|(key, value)| [key, value])
        .collect();
}

fn control_layout(
    customization: &Map<String, Value>,
    identity: &str,
) -> Option<Map<String, Value>> {
    let (kind, value) = identity.split_once(':')?;
    match kind {
        "builtin" => builtin_layout(customization, value),
        "custom" => custom_button(customization, value)?
            .get("layout")
            .and_then(Value::as_object)
            .cloned(),
        "system" if value == "top_bar_activation" => Some(
            customization
                .get("topBarActivationRegion")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_else(default_top_bar_layout),
        ),
        _ => None,
    }
}

fn replace_control_layout(
    customization: &mut Map<String, Value>,
    identity: &str,
    layout: Map<String, Value>,
) -> bool {
    let Some(before_layout) = control_layout(customization, identity) else {
        return false;
    };
    let Some((kind, value)) = identity.split_once(':') else {
        return false;
    };
    match kind {
        "builtin" => replace_builtin_layout(customization, value, before_layout, layout),
        "custom" => replace_custom_layout(customization, value, before_layout, layout),
        "system" if value == "top_bar_activation" => {
            if top_bar_layout_is_default(&layout) {
                customization.remove("topBarActivationRegion");
            } else {
                customization.insert("topBarActivationRegion".to_owned(), Value::Object(layout));
            }
            true
        }
        _ => false,
    }
}

fn replace_builtin_layout(
    customization: &mut Map<String, Value>,
    button: &str,
    before_layout: Map<String, Value>,
    layout: Map<String, Value>,
) -> bool {
    let mut before_layout = normalized_known_layout(before_layout);
    let mut layout = normalized_known_layout(layout);
    for value in [&mut before_layout, &mut layout] {
        value.entry("shape".to_owned()).or_insert_with(|| Value::String("rounded_rectangle".to_owned()));
    }
    let Some(values) = customization
        .entry("buttonCustomizations".to_owned())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
    else {
        return false;
    };
    if values.len() % 2 != 0 {
        return false;
    }
    let position = values.chunks_exact(2).position(|pair| {
        pair[0]
            .as_str()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
    });
    if button_layout_is_default(&layout) {
        if let Some(position) = position {
            values.drain(position * 2..position * 2 + 2);
        }
    } else if let Some(position) = position {
        values[position * 2 + 1] = apply_expected_canonical_changes(
            &values[position * 2 + 1],
            &Value::Object(before_layout.clone()),
            &Value::Object(layout.clone()),
        );
    } else {
        let order = game_button_order(button);
        let insertion = values
            .chunks_exact(2)
            .position(|pair| {
                pair[0]
                    .as_str()
                    .is_some_and(|candidate| game_button_order(candidate) > order)
            })
            .unwrap_or(values.len() / 2)
            * 2;
        values.insert(insertion, Value::String(button.to_owned()));
        values.insert(insertion + 1, Value::Object(layout.clone()));
    }
    if let Some(element) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .and_then(|elements| {
            elements.iter_mut().find(|element| {
                element
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
            })
        })
    {
        element.as_object_mut().is_some_and(|element| {
            let raw = element.get("layout").cloned().unwrap_or(Value::Null);
            element.insert(
                "layout".to_owned(),
                apply_expected_canonical_changes(
                    &raw,
                    &Value::Object(before_layout),
                    &Value::Object(layout),
                ),
            );
            true
        })
    } else {
        true
    }
}

fn replace_custom_layout(
    customization: &mut Map<String, Value>,
    id: &str,
    before_layout: Map<String, Value>,
    layout: Map<String, Value>,
) -> bool {
    let Some(expected) = Uuid::parse_str(id).ok() else {
        return false;
    };
    let Some(button) = customization
        .get_mut("customButtons")
        .and_then(Value::as_array_mut)
        .and_then(|buttons| {
            buttons.iter_mut().find(|button| {
                button
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(|value| Uuid::parse_str(value).ok())
                    == Some(expected)
            })
        })
    else {
        return false;
    };
    let Some(button) = button.as_object_mut() else {
        return false;
    };
    let raw_button_layout = button.get("layout").cloned().unwrap_or(Value::Null);
    button.insert(
        "layout".to_owned(),
        apply_expected_canonical_changes(
            &raw_button_layout,
            &Value::Object(before_layout.clone()),
            &Value::Object(layout.clone()),
        ),
    );
    let Some(element) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .and_then(|elements| {
            elements.iter_mut().find(|element| {
                element
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(|value| Uuid::parse_str(value).ok())
                    == Some(expected)
            })
        })
    else {
        return false;
    };
    let Some(element) = element.as_object_mut() else {
        return false;
    };
    let raw_element_layout = element.get("layout").cloned().unwrap_or(Value::Null);
    element.insert(
        "layout".to_owned(),
        apply_expected_canonical_changes(
            &raw_element_layout,
            &Value::Object(before_layout),
            &Value::Object(layout),
        ),
    );
    true
}

fn set_control_position(
    customization: &mut Map<String, Value>,
    identity: &str,
    x: f64,
    y: f64,
) -> bool {
    let Some((kind, value)) = identity.split_once(':') else {
        return false;
    };
    match kind {
        "builtin" | "custom" | "system" if kind != "system" || value == "top_bar_activation" => {
            let Some(mut layout) = control_layout(customization, identity) else {
                return false;
            };
            layout.insert("centerX".to_owned(), Value::from(x));
            layout.insert("centerY".to_owned(), Value::from(y));
            replace_control_layout(customization, identity, layout)
        }
        _ => false,
    }
}

fn non_overlapping_frame(preferred: Rect, existing: &[Rect], canvas: (f64, f64)) -> Option<Rect> {
    let preferred = clamped_frame(preferred, canvas);
    if !frame_overlaps_any(preferred, existing) {
        return Some(preferred);
    }
    let x_values = candidate_origins(preferred.min_x(), preferred.width, canvas.0, existing, true);
    let y_values = candidate_origins(
        preferred.min_y(),
        preferred.height,
        canvas.1,
        existing,
        false,
    );
    let preferred_center = (preferred.mid_x(), preferred.mid_y());
    let mut best = None;
    let mut best_score = f64::MAX;
    for x in x_values {
        let dx = x + preferred.width / 2.0 - preferred_center.0;
        let x_score = dx * dx;
        if x_score >= best_score {
            break;
        }
        for y in &y_values {
            let dy = *y + preferred.height / 2.0 - preferred_center.1;
            let score = x_score + dy * dy;
            if score >= best_score {
                break;
            }
            let candidate = Rect {
                x,
                y: *y,
                width: preferred.width,
                height: preferred.height,
            };
            if !frame_overlaps_any(candidate, existing) {
                best_score = score;
                best = Some(candidate);
            }
        }
    }
    best
}

fn clamped_frame(frame: Rect, canvas: (f64, f64)) -> Rect {
    Rect {
        x: clamped_origin(frame.x, frame.width, canvas.0),
        y: clamped_origin(frame.y, frame.height, canvas.1),
        ..frame
    }
}

fn clamped_origin(origin: f64, length: f64, canvas: f64) -> f64 {
    if length < canvas {
        origin.clamp(0.0, (canvas - length).max(0.0))
    } else {
        (canvas - length) / 2.0
    }
}

fn candidate_origins(
    preferred: f64,
    length: f64,
    canvas: f64,
    existing: &[Rect],
    horizontal: bool,
) -> Vec<f64> {
    let mut values = vec![preferred];
    if length >= canvas {
        values.push((canvas - length) / 2.0);
    } else {
        values.extend([0.0, canvas - length]);
    }
    for frame in existing {
        let (minimum, maximum) = if horizontal {
            (frame.min_x(), frame.max_x())
        } else {
            (frame.min_y(), frame.max_y())
        };
        values.extend([minimum - length, maximum, minimum, maximum - length]);
    }
    values = values
        .into_iter()
        .map(|value| clamped_origin(value, length, canvas))
        .collect();
    values.sort_by(|left, right| left.total_cmp(right));
    values.dedup_by(|left, right| (*left - *right).abs() < 0.5);
    values.sort_by(|left, right| {
        let left_distance = (*left - preferred).abs();
        let right_distance = (*right - preferred).abs();
        if (left_distance - right_distance).abs() > 0.001 {
            left_distance.total_cmp(&right_distance)
        } else {
            left.total_cmp(right)
        }
    });
    values
}

fn frame_overlaps_any(frame: Rect, existing: &[Rect]) -> bool {
    existing.iter().any(|other| {
        frame.min_x() < other.max_x()
            && frame.max_x() > other.min_x()
            && frame.min_y() < other.max_y()
            && frame.max_y() > other.min_y()
    })
}

fn nearest_separated_frame(
    control: &RepairControl,
    obstacles: &[Rect],
    canvas: (f64, f64),
) -> Rect {
    let original = control.frame();
    let original_hit = control.hit_frame();
    let leading = original.min_x() - original_hit.min_x();
    let top = original.min_y() - original_hit.min_y();
    let canvas_rect = Rect {
        x: 0.0,
        y: 0.0,
        width: canvas.0,
        height: canvas.1,
    };
    let fits = |frame: Rect| {
        canvas_rect.contains(frame)
            && obstacles.iter().all(|obstacle| {
                original_hit
                    .offset(
                        frame.mid_x() - original.mid_x(),
                        frame.mid_y() - original.mid_y(),
                    )
                    .intersection(*obstacle)
                    .is_none()
            })
    };
    if fits(original) {
        return original;
    }
    let mut x_values = vec![original.min_x(), 0.0, canvas.0 - original.width];
    let mut y_values = vec![original.min_y(), 0.0, canvas.1 - original.height];
    for obstacle in obstacles {
        x_values.extend([
            obstacle.min_x() - original_hit.width + leading,
            obstacle.max_x() + leading,
        ]);
        y_values.extend([
            obstacle.min_y() - original_hit.height + top,
            obstacle.max_y() + top,
        ]);
    }
    x_values.retain(|x| *x >= 0.0 && *x + original.width <= canvas.0);
    y_values.retain(|y| *y >= 0.0 && *y + original.height <= canvas.1);
    x_values.sort_by(f64::total_cmp);
    y_values.sort_by(f64::total_cmp);
    x_values.dedup_by(|left, right| *left == *right);
    y_values.dedup_by(|left, right| *left == *right);
    let mut candidates = x_values
        .into_iter()
        .flat_map(|x| {
            y_values.iter().map(move |y| Rect {
                x,
                y: *y,
                width: original.width,
                height: original.height,
            })
        })
        .filter(|frame| fits(*frame))
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| {
        let left_distance = distance(
            left.mid_x(),
            left.mid_y(),
            original.mid_x(),
            original.mid_y(),
        );
        let right_distance = distance(
            right.mid_x(),
            right.mid_y(),
            original.mid_x(),
            original.mid_y(),
        );
        if (left_distance - right_distance).abs() > 0.001 {
            left_distance.total_cmp(&right_distance)
        } else if (left.min_y() - right.min_y()).abs() > 0.001 {
            left.min_y().total_cmp(&right.min_y())
        } else {
            left.min_x().total_cmp(&right.min_x())
        }
    });
    candidates.first().copied().unwrap_or(original)
}

fn overlap_issues(controls: &[RepairControl]) -> Vec<RepairIssue> {
    let mut issues = Vec::new();
    for back_index in 0..controls.len() {
        for front_index in back_index + 1..controls.len() {
            let back = &controls[back_index];
            let front = &controls[front_index];
            let visual = back.frame().intersection(front.frame());
            let back_hit = back.hit_frame();
            let front_hit = front.hit_frame();
            let Some(hit) = back_hit.intersection(front_hit) else {
                continue;
            };
            let controls = vec![back.identity.clone(), front.identity.clone()];
            if let Some(visual) = visual {
                let ratio = visual.area() / back.frame().area().min(front.frame().area()).max(1.0);
                if ratio > 0.015 {
                    issues.push(RepairIssue {
                        code: "control-overlap",
                        controls: controls.clone(),
                        severity: 1,
                    });
                }
            } else {
                issues.push(RepairIssue {
                    code: "expanded-hit-overlap",
                    controls: controls.clone(),
                    severity: 1,
                });
            }
            let front_wins = front.touch_priority() < back.touch_priority()
                || (front.touch_priority() == back.touch_priority()
                    && front_hit.area() < back_hit.area() - 0.5);
            let equal = front.touch_priority() == back.touch_priority()
                && (front_hit.area() - back_hit.area()).abs() <= 0.5;
            if equal {
                issues.push(RepairIssue {
                    code: "hit-region-z-order-ambiguous",
                    controls,
                    severity: 1,
                });
            } else if !front_wins {
                issues.push(RepairIssue {
                    code: "hit-region-z-order-mismatch",
                    controls,
                    severity: 1,
                });
            }
            let _ = hit;
        }
    }
    issues
}

fn size_issues(controls: &[RepairControl]) -> Vec<RepairIssue> {
    controls
        .iter()
        .filter(|control| control.width.min(control.height) < 44.0)
        .map(|control| RepairIssue {
            code: "small-control",
            controls: vec![control.identity.clone()],
            severity: 1,
        })
        .collect()
}

fn edge_issues(controls: &[RepairControl], canvas: (f64, f64)) -> Vec<RepairIssue> {
    let margin = (canvas.0.min(canvas.1) * 0.006).max(2.0);
    controls
        .iter()
        .filter(|control| {
            let frame = control.frame();
            frame.min_x() < margin
                || frame.min_y() < margin
                || frame.max_x() > canvas.0 - margin
                || frame.max_y() > canvas.1 - margin
        })
        .map(|control| RepairIssue {
            code: "edge-hugging-control",
            controls: vec![control.identity.clone()],
            severity: 1,
        })
        .collect()
}

fn utilization_issues(controls: &[RepairControl], canvas: (f64, f64)) -> Vec<RepairIssue> {
    if controls.len() < 8 {
        return Vec::new();
    }
    let Some(bounds) = union_frames(controls.iter().map(RepairControl::frame)) else {
        return Vec::new();
    };
    if bounds.width <= 1.0 || bounds.height <= 1.0 {
        return Vec::new();
    }
    let width = bounds.width / canvas.0.max(1.0);
    let height = bounds.height / canvas.1.max(1.0);
    let bottom = (canvas.1 - bounds.max_y()).max(0.0) / canvas.1.max(1.0);
    let ids: Vec<String> = controls
        .iter()
        .map(|control| control.identity.clone())
        .collect();
    let mut issues = Vec::new();
    if bottom > 0.18 {
        issues.push(RepairIssue {
            code: "underused-bottom-space",
            controls: ids.clone(),
            severity: 1,
        });
    }
    if height < 0.70 {
        issues.push(RepairIssue {
            code: "low-vertical-coverage",
            controls: ids.clone(),
            severity: 1,
        });
    }
    if width < 0.55 {
        issues.push(RepairIssue {
            code: "low-horizontal-coverage",
            controls: ids,
            severity: 1,
        });
    }
    issues
}

fn uses_freeform_layout(customization: &Map<String, Value>) -> bool {
    if customization
        .get("elements")
        .and_then(Value::as_array)
        .is_some_and(|elements| !elements.is_empty())
    {
        return true;
    }
    if customization
        .get("customButtons")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .any(|button| {
            !button
                .get("layout")
                .and_then(|layout| layout.get("isHidden"))
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
    {
        return true;
    }
    BUILTINS.iter().any(|button| {
        builtin_layout(customization, button).is_some_and(|layout| {
            layout.contains_key("centerX")
                || layout.contains_key("centerY")
                || (layout
                    .get("widthScale")
                    .and_then(Value::as_f64)
                    .unwrap_or(1.0)
                    - 1.0)
                    .abs()
                    >= 0.001
                || (layout
                    .get("heightScale")
                    .and_then(Value::as_f64)
                    .unwrap_or(1.0)
                    - 1.0)
                    .abs()
                    >= 0.001
                || layout
                    .get("rotationDegrees")
                    .and_then(Value::as_f64)
                    .unwrap_or(0.0)
                    .abs()
                    >= 0.001
                || layout.get("zIndex").and_then(Value::as_i64).unwrap_or(0) != 0
                || layout.contains_key("hitInsets")
                || layout.contains_key("shape")
                || layout
                    .get("isHidden")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        })
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ReachMode {
    TwoHanded,
    OneHandedLeft,
    OneHandedRight,
}

fn reach_mode(customization: &Map<String, Value>) -> ReachMode {
    let tags = customization
        .get("designMetadata")
        .and_then(|value| value.get("tags"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|tag| tag.trim().to_ascii_lowercase())
        .collect::<std::collections::BTreeSet<_>>();
    if tags.contains("left-hand") || tags.contains("one-handed-left") {
        ReachMode::OneHandedLeft
    } else if tags.contains("right-hand") || tags.contains("one-handed-right") {
        ReachMode::OneHandedRight
    } else {
        ReachMode::TwoHanded
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ErgonomicRole {
    Movement,
    Action,
    Utility,
    Exempt,
}

fn ergonomic_role(control: &RepairControl) -> ErgonomicRole {
    if control.is_decoration() || control.is_joystick() || control.is_trackpad() || control.is_trigger() {
        return ErgonomicRole::Exempt;
    }
    match control.visual_role.as_deref() {
        Some("movement") => return ErgonomicRole::Movement,
        Some("utility" | "menu") => return ErgonomicRole::Utility,
        Some("decoration" | "system" | "joystick" | "trackpad" | "trigger") => return ErgonomicRole::Exempt,
        Some("primary_action" | "secondary_action") => return ErgonomicRole::Action,
        _ => {}
    }
    if control.identity.starts_with("custom:") && is_utility_label(&control.label) {
        return ErgonomicRole::Utility;
    }
    match control.element_id.and_then(|id| id.starter_index()) {
        Some(1..=4) => ErgonomicRole::Movement,
        Some(9..=10) => ErgonomicRole::Utility,
        _ => ErgonomicRole::Action,
    }
}

fn is_utility_label(label: &str) -> bool {
    let label = label.trim().to_ascii_lowercase();
    matches!(
        label.as_str(),
        "+" | "-"
            | "−"
            | "l"
            | "r"
            | "zl"
            | "zr"
            | "lb"
            | "rb"
            | "lt"
            | "rt"
            | "menu"
            | "start"
            | "select"
            | "back"
            | "home"
            | "options"
            | "share"
            | "coin"
            | "utility"
    ) || label.contains("shoulder")
        || label.contains("bumper")
}

fn ergonomic_issues(
    controls: &[RepairControl],
    canvas: (f64, f64),
    mode: ReachMode,
) -> Vec<RepairIssue> {
    let portrait = canvas.1 > canvas.0;
    controls
        .iter()
        .filter_map(|control| {
            let role = ergonomic_role(control);
            if !matches!(role, ErgonomicRole::Movement | ErgonomicRole::Action) {
                return None;
            }
            let x = control.center_x / canvas.0.max(1.0);
            let y = control.center_y / canvas.1.max(1.0);
            let side_x = match mode {
                ReachMode::TwoHanded if role == ErgonomicRole::Movement => {
                    if portrait {
                        0.27
                    } else {
                        0.18
                    }
                }
                ReachMode::TwoHanded => {
                    if portrait {
                        0.73
                    } else {
                        0.82
                    }
                }
                ReachMode::OneHandedLeft => {
                    if portrait {
                        0.27
                    } else {
                        0.25
                    }
                }
                ReachMode::OneHandedRight => {
                    if portrait {
                        0.73
                    } else {
                        0.75
                    }
                }
            };
            let anchor_y = if portrait { 0.76 } else { 0.68 };
            let horizontal = if mode == ReachMode::TwoHanded {
                if portrait {
                    0.36
                } else {
                    0.34
                }
            } else if portrait {
                0.48
            } else {
                0.50
            };
            let vertical = if portrait { 0.38 } else { 0.43 };
            let reach = ((x - side_x) / horizontal).hypot((y - anchor_y) / vertical);
            let code = if y < if portrait { 0.24 } else { 0.20 } {
                "primary-control-too-high"
            } else if mode == ReachMode::TwoHanded
                && (0.40..=0.60).contains(&x)
                && y < if portrait { 0.78 } else { 0.74 }
            {
                "primary-control-too-central"
            } else if reach > 1.25 {
                "primary-control-out-of-reach"
            } else {
                return None;
            };
            Some(RepairIssue {
                code,
                controls: vec![control.identity.clone()],
                severity: 1,
            })
        })
        .collect()
}

fn portrait_issues(
    controls: &[RepairControl],
    canvas: (f64, f64),
    mode: ReachMode,
) -> Vec<RepairIssue> {
    let primary = controls
        .iter()
        .filter(|control| {
            matches!(
                ergonomic_role(control),
                ErgonomicRole::Movement | ErgonomicRole::Action
            )
        })
        .collect::<Vec<_>>();
    let mut issues = Vec::new();
    if mode == ReachMode::TwoHanded && primary.len() >= 4 {
        let left = primary
            .iter()
            .filter(|control| {
                control.center_x < canvas.0 * 0.48 && control.center_y > canvas.1 * 0.52
            })
            .count();
        let right = primary
            .iter()
            .filter(|control| {
                control.center_x > canvas.0 * 0.52 && control.center_y > canvas.1 * 0.52
            })
            .count();
        if left == 0 || right == 0 {
            let mut ids = primary
                .iter()
                .map(|control| control.identity.clone())
                .collect::<Vec<_>>();
            ids.sort();
            issues.push(RepairIssue {
                code: "portrait-primary-action-distribution",
                controls: ids,
                severity: 1,
            });
        }
    }
    if controls.len() >= 6 && largest_internal_vertical_gap(controls, canvas.1) > 0.30 {
        let mut ids = controls
            .iter()
            .map(|control| control.identity.clone())
            .collect::<Vec<_>>();
        ids.sort();
        issues.push(RepairIssue {
            code: "portrait-dead-space",
            controls: ids,
            severity: 1,
        });
    }
    issues
}

fn largest_internal_vertical_gap(controls: &[RepairControl], canvas_height: f64) -> f64 {
    let mut intervals = controls
        .iter()
        .filter_map(|control| {
            let frame = control.frame();
            let start = frame.min_y().max(0.0);
            let end = frame.max_y().min(canvas_height);
            (end > start).then_some((start, end))
        })
        .collect::<Vec<_>>();
    intervals.sort_by(|left, right| {
        left.0
            .total_cmp(&right.0)
            .then_with(|| left.1.total_cmp(&right.1))
    });
    let Some(mut active) = intervals.first().copied() else {
        return 0.0;
    };
    let mut largest: f64 = 0.0;
    for interval in intervals.into_iter().skip(1) {
        if interval.0 > active.1 {
            largest = largest.max(interval.0 - active.1);
            active = interval;
        } else {
            active.1 = active.1.max(interval.1);
        }
    }
    largest / canvas_height.max(1.0)
}

fn issue_order(left: &RepairIssue, right: &RepairIssue) -> Ordering {
    left.severity
        .cmp(&right.severity)
        .then_with(|| left.code.cmp(right.code))
        .then_with(|| left.controls.cmp(&right.controls))
}

fn issue_priority(code: &str) -> u8 {
    match code {
        "no-visible-controls" => 0,
        "small-control" => 1,
        "layout-displacement" | "edge-hugging-control" => 2,
        "control-overlap"
        | "expanded-hit-overlap"
        | "hit-region-z-order-ambiguous"
        | "hit-region-z-order-mismatch" => 3,
        "primary-control-too-high"
        | "primary-control-too-central"
        | "primary-control-out-of-reach"
        | "portrait-primary-action-distribution"
        | "portrait-dead-space" => 4,
        "underused-bottom-space" | "low-vertical-coverage" | "low-horizontal-coverage" => 5,
        _ => 6,
    }
}

fn ergonomic_control_order(left: &RepairControl, right: &RepairControl) -> Ordering {
    ergonomic_button_order(left.element_id)
        .cmp(&ergonomic_button_order(right.element_id))
        .then_with(|| left.stable_id.cmp(&right.stable_id))
}

fn ergonomic_button_order(element_id: Option<thumble_protocol::KeypadElementID>) -> i32 {
    match element_id.and_then(|id| id.starter_index()) {
        Some(1) => 0,
        Some(3) => 1,
        Some(4) => 2,
        Some(2) => 3,
        Some(index) => index as i32 - 1,
        None => 100,
    }
}

fn cluster_positions(
    controls: &[RepairControl],
    anchor: (f64, f64),
    movement: bool,
    canvas: (f64, f64),
) -> Vec<(String, f64, f64)> {
    if controls.is_empty() {
        return Vec::new();
    }
    let maximum = controls
        .iter()
        .map(|control| control.width.max(control.height))
        .fold(44.0, f64::max);
    let step = maximum + HIT_OUTSET * 2.0 + 2.0;
    let pattern = if movement {
        [(0.0, -1.0), (-1.0, 0.0), (1.0, 0.0), (0.0, 1.0)]
    } else {
        [(0.0, 1.0), (-1.0, 0.0), (1.0, 0.0), (0.0, -1.0)]
    };
    controls
        .iter()
        .enumerate()
        .map(|(index, control)| {
            let ring = index / pattern.len() + 1;
            let point = pattern[index % pattern.len()];
            let proposed = (
                anchor.0 + point.0 * step * ring as f64,
                anchor.1 + point.1 * step * ring as f64,
            );
            let (x, y) = normalized_position(
                proposed.0,
                proposed.1,
                control.width,
                control.height,
                canvas,
            );
            (control.identity.clone(), x, y)
        })
        .collect()
}

fn one_handed_positions(
    controls: &[RepairControl],
    anchor: (f64, f64),
    canvas: (f64, f64),
) -> Vec<(String, f64, f64)> {
    if controls.is_empty() {
        return Vec::new();
    }
    let maximum = controls
        .iter()
        .map(|control| control.width.max(control.height))
        .fold(44.0, f64::max);
    let step = maximum + HIT_OUTSET * 2.0 + 2.0;
    controls
        .iter()
        .enumerate()
        .map(|(index, control)| {
            let column = (index % 3) as f64 - 1.0;
            let row = (index / 3) as f64;
            let (x, y) = normalized_position(
                anchor.0 + column * step,
                anchor.1 - row * step,
                control.width,
                control.height,
                canvas,
            );
            (control.identity.clone(), x, y)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn issue_priority_matches_canonical_groups() {
        assert!(issue_priority("small-control") < issue_priority("control-overlap"));
        assert!(issue_priority("control-overlap") < issue_priority("portrait-dead-space"));
        assert!(issue_priority("portrait-dead-space") < issue_priority("low-vertical-coverage"));
    }

    type MaliciousMutation = (&'static str, fn(&mut ConfigurationDocument));

    fn golden_document(customization: Value, updated_at: i64) -> ConfigurationDocument {
        serde_json::from_value(serde_json::json!({
            "profiles": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "Fixture",
                "customization": customization,
                "landscapeCustomization": customization,
                "updatedAt": updated_at
            }],
            "activeProfileID": "00000000-0000-0000-0000-000000000001",
            "defaultProfileID": "00000000-0000-0000-0000-000000000001",
            "keyBindings": {}, "outputBindings": {},
            "profileKeyBindings": {}, "profileOutputBindings": {}
        }))
        .unwrap()
    }

    #[test]
    fn independent_reconstruction_matches_swift_goldens_and_rejects_injection() {
        let fixture: Value =
            serde_json::from_str(include_str!("../tests/fixtures/customization-fix-v1.json"))
                .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let operation: ConfigurationOperation = serde_json::from_value(serde_json::json!({
                "type": "customization.fix",
                "profileID": "00000000-0000-0000-0000-000000000001",
                "variant": "primary",
                "target": case["target"].clone(),
                "canvas": case["canvas"].clone(),
                "includeLocked": case["includeLocked"].clone()
            }))
            .unwrap();
            let before = golden_document(case["before"].clone(), 0);
            let changed = case["before"] != case["after"];
            let after = golden_document(case["after"].clone(), if changed { 42 } else { 0 });
            if !valid_operation_delta(&before, &after, &operation) {
                let ConfigurationOperation::CustomizationFix {
                    target,
                    canvas,
                    include_locked,
                    ..
                } = &operation
                else {
                    unreachable!()
                };
                let before_customization = case["before"].as_object().unwrap().clone();
                let size = repair_canvas_size(&before_customization, canvas).unwrap();
                let mut engine = RepairEngine::new(before_customization, size, !include_locked);
                assert!(engine.apply_target(target));
                panic!(
                    "{} first diff: {:?}",
                    case["name"].as_str().unwrap(),
                    first_difference(&Value::Object(engine.customization), &case["after"], "$")
                );
            }

            let mut injected = after.clone();
            injected.profiles[0]["customization"]["backgroundImage"] =
                serde_json::json!({"path":"/tmp/private"});
            assert!(
                !valid_operation_delta(&before, &injected, &operation),
                "injection accepted for {}",
                case["name"].as_str().unwrap()
            );
            if case["name"] == "custom-mirror-minimum-touch-target" {
                let mut malformed_mirror = after.clone();
                let elements = malformed_mirror.profiles[0]["customization"]["elements"]
                    .as_array_mut()
                    .unwrap();
                let custom = elements
                    .iter_mut()
                    .find(|element| element.get("id").and_then(Value::as_str)
                        .and_then(thumble_protocol::KeypadElementID::parse)
                        .is_some_and(|id| id.starter_index().is_none()))
                    .unwrap();
                custom["layout"]["centerX"] = Value::from(0.9);
                assert!(!valid_operation_delta(
                    &before,
                    &malformed_mirror,
                    &operation
                ));

                let mut undeclared = after.clone();
                undeclared.profiles[0]["customization"]["customButtons"]
                    .as_array_mut()
                    .unwrap()
                    .push(serde_json::json!({
                        "id":"00000000-0000-0000-0000-00000000dead",
                        "label":"Injected",
                        "layout":{}, "controlKind":"button"
                    }));
                assert!(!valid_operation_delta(&before, &undeclared, &operation));
            }
            if case["name"] == "minimum-touch-target" {
                let mut tiny_drift = after.clone();
                for key in ["customization", "landscapeCustomization"] {
                    perturb_geometry(&mut tiny_drift.profiles[0][key], 5e-13);
                }
                assert!(valid_operation_delta(&before, &tiny_drift, &operation));
                let mut excessive_drift = after.clone();
                for key in ["customization", "landscapeCustomization"] {
                    perturb_geometry(&mut excessive_drift.profiles[0][key], 2e-11);
                }
                assert!(!valid_operation_delta(
                    &before,
                    &excessive_drift,
                    &operation
                ));

                let mutations: [MaliciousMutation; 5] = [
                    ("profile", |document: &mut ConfigurationDocument| {
                        document.profiles[0]["name"] = Value::String("Injected".to_owned());
                    }),
                    ("element label", |document: &mut ConfigurationDocument| {
                        document.profiles[0]["customization"]["elements"][0]["label"] =
                            Value::String("Injected".to_owned());
                    }),
                    ("element output", |document: &mut ConfigurationDocument| {
                        document.profiles[0]["customization"]["elements"][0]["output"] =
                            serde_json::json!({"keyboard":{"keyCode":49}});
                    }),
                    ("style", |document: &mut ConfigurationDocument| {
                        document.profiles[0]["customization"]["styleLibrary"] =
                            serde_json::json!({"styles":[{"id":"injected"}]});
                    }),
                    ("group", |document: &mut ConfigurationDocument| {
                        document.profiles[0]["customization"]["designMetadata"] =
                            serde_json::json!({"groups":[{"id":"injected"}]});
                    }),
                ];
                for (label, mutate) in mutations {
                    let mut malicious = after.clone();
                    mutate(&mut malicious);
                    assert!(
                        !valid_operation_delta(&before, &malicious, &operation),
                        "{label} injection accepted"
                    );
                }
            }
        }
    }

    fn perturb_geometry(value: &mut Value, amount: f64) {
        match value {
            Value::Object(object) => {
                for (key, value) in object {
                    if matches!(
                        key.as_str(),
                        "centerX" | "centerY" | "widthScale" | "heightScale"
                    ) {
                        if let Some(number) = value.as_f64() {
                            *value = Value::from(number + amount);
                        }
                    } else {
                        perturb_geometry(value, amount);
                    }
                }
            }
            Value::Array(values) => {
                for value in values {
                    perturb_geometry(value, amount);
                }
            }
            _ => {}
        }
    }

    fn first_difference(left: &Value, right: &Value, path: &str) -> Option<String> {
        match (left, right) {
            (Value::Object(left), Value::Object(right)) => {
                for key in left.keys().chain(right.keys()) {
                    if left.get(key) != right.get(key) {
                        let child = format!("{path}.{key}");
                        return first_difference(
                            left.get(key).unwrap_or(&Value::Null),
                            right.get(key).unwrap_or(&Value::Null),
                            &child,
                        )
                        .or(Some(child));
                    }
                }
                None
            }
            (Value::Array(left), Value::Array(right)) => {
                for index in 0..left.len().max(right.len()) {
                    if left.get(index) != right.get(index) {
                        let child = format!("{path}[{index}]");
                        return first_difference(
                            left.get(index).unwrap_or(&Value::Null),
                            right.get(index).unwrap_or(&Value::Null),
                            &child,
                        )
                        .or(Some(child));
                    }
                }
                None
            }
            _ if !layout_fix_semantically_equal(left, right, None) => {
                Some(format!("{path}: {left} != {right}"))
            }
            _ => None,
        }
    }

    #[test]
    fn bounded_canvas_rejects_nonfinite_and_out_of_range_sizes() {
        let customization = Map::new();
        assert!(repair_canvas_size(
            &customization,
            &LayoutRepairCanvas::Size {
                width: f64::NAN,
                height: 400.0
            }
        )
        .is_none());
        assert!(repair_canvas_size(
            &customization,
            &LayoutRepairCanvas::Size {
                width: 239.0,
                height: 400.0
            }
        )
        .is_none());
    }
}
