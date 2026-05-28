# ipe-typst-adapter

Ipe から Typst CLI を呼び出し、Typst ソースをレンダリングした図形を Ipe に挿入する MVP ipelet です。

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

## MVP の制限

- Typst ラベルは Ipe text ではなく group object です。
- 通常の Ipe text editor では編集できません。
- baseline alignment は未対応です。
- bounding box は Typst の `auto` page size 由来の暫定実装です。
- 背景は透明です。
- Flatpak 版 Ipe では PATH や sandbox の都合で `typst` / `svgtoipe` が見えない可能性があります。
- 複数 Typst ラベルの一括再レンダリング、キャッシュ、daemon 化は未対応です。

## custom data

挿入した group object の custom data に `ipe-typst` メタデータを保存します。

MVP で保存する情報は次です。

```json
{
  "kind": "ipe-typst-label",
  "version": 1,
  "source": "..."
}
```

実際の保存形式は Lua 側で安全に読み書きできる行ベース形式です。
