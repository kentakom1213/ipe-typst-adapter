# ipe-typst-adapter

Ipe から Typst CLI を呼び出し、Typst ソースをレンダリングした図形を Ipe に挿入する ipelet です。

Typst ラベルは Ipe の通常 `text` オブジェクトではなく、元の Typst ソースを custom data に保存した再生成可能な `group` オブジェクトとして扱います。

## 必要な依存関係

- Ipe
- Typst CLI (`typst`)
- svgtoipe (`svgtoipe`)

`typst` と `svgtoipe` は、Ipe から見える `PATH` 上で実行できる必要があります。

## インストール

`ipelets/typst.lua` を Ipe の ipelets directory に置いてください。

例:

```sh
cp ipelets/typst.lua ~/.ipe/ipelets/
```

配置後、Ipe を再起動すると ipelet メニューに `Typst` が表示されます。

## 使い方

### Insert

`Typst > Insert Typst Label...` を選び、Typst ソースを入力します。

内部では次のパイプラインで Ipe オブジェクトを生成します。

```txt
Typst source
  -> temporary .typ
  -> typst compile
  -> .svg
  -> svgtoipe
  -> .ipe
  -> Ipe group object
```

### Edit

挿入済みの Typst ラベルを 1 つ選択し、`Typst > Edit Typst Label...` を選びます。
保存されている Typst ソースを初期値として編集し、再レンダリングした group object に差し替えます。

### Re-render

挿入済みの Typst ラベルを 1 つ選択し、`Typst > Re-render Typst Label` を選びます。
保存済みの Typst ソースを使って再描画します。

## 設定

デフォルト設定は `ipelets/typst.lua` の先頭にあります。さらに、存在する場合は `~/.ipe/ipe-typst.lua` を読み込み、設定を上書きします。

例:

```lua
return {
  compile_command = "typst compile --format svg --font-path /home/powell/.local/share/fonts {input} {output}",
  svgtoipe_command = "svgtoipe {input} {output}",
  font_family = "Noto Sans CJK JP",
  text_size_pt = 10,
  shortcuts = {
    insert = "Ctrl+Shift+L",
    edit = "Ctrl+Shift+E",
    rerender = "Ctrl+Alt+R",
  },
}
```

`compile_command` と `svgtoipe_command` では、次の placeholder を使えます。

- `{input}`: 入力ファイル
- `{output}`: 出力ファイル
- `{dir}`: 一時ディレクトリ

`{input}` と `{output}` は必須です。ファイルパスは ipelet 側で shell quote してから展開します。

日本語フォントを使う場合は、先に Typst からフォントが見えているか確認してください。

```sh
typst fonts
typst fonts --font-path ~/.local/share/fonts
```

表示されたフォント名を `font_family` に設定してください。`font_family` が未設定の場合、wrapper 文書ではフォントを指定しません。

`compile_command` と `svgtoipe_command` は shell に渡されます。信頼できるローカル設定だけを使ってください。

### ショートカット

`shortcuts` では次の操作に Ipe のキーボードショートカットを指定できます。

- `insert`: `Insert Typst Label...`
- `edit`: `Edit Typst Label...`
- `rerender`: `Re-render Typst Label`

Ipe を再起動すると反映されます。ショートカット文字列は Ipe の `shortcuts.lua` と同じ形式です。例: `Ctrl+Alt+T`, `Shift+J`, `F5`。

## 注意

- Typst ラベルは Ipe text ではなく group object です。
- 通常の Ipe text editor では編集できません。
- baseline alignment は未対応です。
- bounding box は Typst の `auto` page size 由来の暫定実装です。
- 背景は透明です。
- Flatpak 版 Ipe では PATH や sandbox の都合で `typst` / `svgtoipe` が見えない可能性があります。
- 複数 Typst ラベルの一括再レンダリング、キャッシュ、daemon 化は未対応です。

## custom data

挿入した group object の custom data に `ipe-typst` メタデータを保存します。

保存する情報は次です。

```json
{
  "kind": "ipe-typst-label",
  "version": 1,
  "source": "..."
}
```

実際の保存形式は Lua 側で安全に読み書きできる行ベース形式です。
