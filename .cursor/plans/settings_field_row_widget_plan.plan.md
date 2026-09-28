---
name: Settings Field Row Widget
overview: 创建一组可复用的「标题 + 控件(文本/开关/下拉) + 描述」Widget，并替换 SettingsBasicPage 内的现有元素，提升 UI 美观性与一致性。
todos: []
isProject: false
---

# 设定项行组件规划

## 一、目标

1. 创建可复用的 **SettingsFieldRow** 组件，统一结构：`title + {textfield / switch / pulldownbutton} + description`
2. 注重 UI 美观性：配色、图标、间距、圆角等
3. 替换 `SettingsBasicPage` 内 `_buildFieldRow` 的现有实现，统一使用新组件

---

## 二、组件结构设计

### 2.1 布局结构

```
┌─────────────────────────────────────────────────────┐
│ [Icon]  Title                           [Control]   │
│         或                                             │
│         Description (小号灰色，换行)                      │
└─────────────────────────────────────────────────────┘
```

- **左侧**：圆角矩形图标容器，支持自定义背景色/前景色（按业务分组差异化）
- **中间**：标题 + 描述（description 可空，有则显示在标题下方）
- **右侧**：控件区（文本展示 / 开关 / 下拉选择 / 文本+复制按钮）

### 2.2 控件类型对应


| 类型       | 控件形式                     | 说明                      |
| -------- | ------------------------ | ----------------------- |
| text     | 纯文本展示                    | 右对齐，灰色，可省略号             |
| textCopy | 文本 + 复制图标按钮              | 文本展示 + 右侧复制按钮           |
| number   | 数值 + 单位                  | 如 "6 小时"                |
| select   | 当前值 + 下拉箭头               | 展示枚举文案，右箭头示意可点击（v2 可编辑） |
| toggle   | CupertinoSwitch 或只读「开/关」 | 第一阶段只读展示，v2 可切换         |


### 2.3 配色与图标

- **图标容器**：背景色使用 `color.withValues(alpha: 0.15)` 或 `0.2`，保证与前景图标对比度
- **主题色建议**：
  - 基础配置：`CupertinoColors.systemBlue` 或 `Colors.blue`
  - 智能助手：`CupertinoColors.systemPurple` 或 `Colors.deepPurple`
  - 可通过 `iconColor` 参数传入，实现分组差异化
- **描述文字**：`CupertinoColors.tertiaryLabel`，字号 12–13
- **标题**：系统默认 15–17，字重 400–500

---

## 三、Widget API 设计

### 3.1 SettingsFieldRow

```dart
/// 设定项行：标题 + 控件 + 描述
class SettingsFieldRow extends StatelessWidget {
  const SettingsFieldRow({
    required this.title,
    required this.control,
    this.description,
    this.icon,
    this.iconColor,
    this.iconBackgroundColor,
  });

  final String title;
  final Widget control;           // 右侧控件，由调用方根据 type 构造
  final String? description;
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBackgroundColor;
}
```

### 3.2 工厂方法（可选，便于快速构建）

```dart
// 静态方法，根据 value + type 自动生成 control
SettingsFieldRow.textRow({...});
SettingsFieldRow.switchRow({...});
SettingsFieldRow.selectRow({...});
SettingsFieldRow.textCopyRow({...});
```

---

## 四、文件组织


| 文件                                                     | 说明                                           |
| ------------------------------------------------------ | -------------------------------------------- |
| `lib/modules/settings/widgets/settings_field_row.dart` | 新建，SettingsFieldRow 组件                       |
| `lib/modules/settings/pages/settings_basic_page.dart`  | 修改，移除 `_buildFieldRow`，改用 `SettingsFieldRow` |


---

## 五、SettingsFieldRow 内部实现要点

1. **图标区域**：
  - 固定尺寸容器（如 32×32 或 36×36）
  - `BoxDecoration`：`color`、`borderRadius: 8`
  - 无 icon 时可隐藏或使用占位
2. **文字区**：
  - `Column(crossAxisAlignment: start)`：title + 可选 description
  - description 与 title 间距 4–6px
  - 支持 `Expanded` 保证长标题/描述正常换行
3. **控件区**：
  - 右对齐，最小宽度满足复制按钮/开关等
  - 与 CupertinoListSection 风格一致（内边距、分割线由 ListSection 处理）
4. **整体**：
  - 使用 `Row` 或 `CupertinoListTile` 作为容器
  - 若用自定义 Row，需保证触摸区域、无障碍支持

---

## 六、SettingsBasicPage 改造

1. 在 `_buildFieldRow` 中，根据 `field.type` 构造对应的 `control` Widget
2. 将 `CupertinoListTile.notched` + 自定义 leading/subtitle 替换为 `SettingsFieldRow`
3. 传入 `field.label`、`field.hint`、`field.icon`，以及由 `_formatValue` + type 生成的 `control`
4. 图标色可按 section 区分：基础配置用 blue，智能助手用 purple（或统一用 blue）
5. 保持现有加载/错误/空状态逻辑不变

---

## 七、实施顺序

1. 创建 `lib/modules/settings/widgets/settings_field_row.dart`，实现 `SettingsFieldRow`
2. 在 `SettingsBasicPage` 中引入并替换 `_buildFieldRow` 的返回内容
3. 调整图标配色、间距，确保与 iOS 风格协调
4. 运行验证，确认各类型（text/select/number/toggle/textCopy）展示正确

