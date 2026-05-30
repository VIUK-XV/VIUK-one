# SafeKids Search 3.1

安全で子ども向けに最適化された検索アプリケーション。iOS、macOS、visionOS に対応したクロスプラットフォーム SwiftUI アプリです。

## 📱 概要

**SafeKids Search 3.1** は、子どもたちが安全にインターネットを検索できるように設計された iOS/macOS/visionOS アプリケーションです。このバージョンでは SwiftUI を採用し、最新の Apple プラットフォームに対応しています。

### 主な特徴
- 🔍 **キッズ向け検索機能** - 年齢に適切なコンテンツをフィルタリング
- 🛡️ **安全なブラウジング** - 不適切なサイトへのアクセスを制限
- 📱 **クロスプラットフォーム対応** - iPhone、iPad、Mac、Vision Pro で動作
- 🎨 **モダン UI** - SwiftUI による快適なインターフェース
- 🌙 **ダークモード対応** - システム設定に合わせた自動切り替え

## 🛠️ 技術スタック

- **言語**: Swift 5.0
- **UI フレームワーク**: SwiftUI
- **対応 OS**:
  - iOS 26.1 以上
  - macOS 26.1 以上
  - visionOS 26.1 以上
- **開発ツール**: Xcode 26.1.1
- **開発チーム ID**: 34CN68272C

## 📋 プロジェクト構成

```
SafeKids Search3.1/
├── SafeKids_Search3_1App.swift      # アプリケーションエントリーポイント
├── ContentView.swift                 # メイン UI
└── Preview Assets/

SafeKids Search3.1Tests/              # ユニットテスト
└── ...

SafeKids Search3.1UITests/            # UI テスト
├── SafeKids_Search3_1UITests.swift
└── SafeKids_Search3_1UITestsLaunchTests.swift

SafeKids Search3.1.xcodeproj/         # Xcode プロジェクト設定
└── project.pbxproj
```

## 🚀 クイックスタート

### システム要件
- Xcode 26.1.1 以上
- Swift 5.0
- macOS 13 以上（開発環境）

### インストール

1. リポジトリをクローン:
```bash
git clone https://github.com/VIUK-XV/VIUK-one.git
cd VIUK-one
```

2. Xcode でプロジェクトを開く:
```bash
open "SafeKids Search3.1.xcodeproj"
```

3. ビルドスキームを選択して実行:
   - Xcode の Product メニューから "Scheme" を選択
   - iOS Simulator、Mac、または実機を選択
   - Cmd + R でビルドして実行

### デバイスでの実行
1. Apple ID でサインイン
2. 開発チーム ID が自動で設定されます
3. 実機を接続して Cmd + R で実行

## 🧪 テスト

### ユニットテスト実行
```bash
xcodebuild test -scheme "SafeKids Search3.1Tests"
```

### UI テスト実行
```bash
xcodebuild test -scheme "SafeKids Search3.1UITests"
```

### Xcode での実行
- Product > Test (Cmd + U)

## 📁 ファイル説明

### SafeKids_Search3_1App.swift
アプリケーションのエントリーポイント。`@main` 属性でアプリを初期化し、`WindowGroup` で `ContentView` を表示します。

**主要な役割**:
- アプリケーションの起動処理
- ウィンドウシーンの管理
- ContentView の表示

### ContentView.swift
メイン UI コンポーネント。現在のところ基本的なテンプレート実装で、以下の要素で構成:
- グローブアイコン表示
- "Hello, world!" テキスト
- SwiftUI Preview サポート

**今後の拡張予定**:
- 検索バーの実装
- コンテンツフィルタリング設定
- 検索履歴表示
- 安全性レベル設定

## 🔧 開発ガイド

### コード構成
- **MVVM パターン**: 将来の拡張に備えた構造
- **SwiftUI**: 宣言的 UI 設計
- **Preview**: 開発効率化のための SwiftUI Preview 活用

### ビルド設定
- **Bundle ID**: `VIUK-app.SafeKids-Search3-1`
- **アプリグループ**: 有効化（REGISTER_APP_GROUPS = YES）
- **App Sandbox**: 有効化
- **Hardened Runtime**: 有効化

### デプロイメント設定
| プラットフォーム | バージョン | デバイス対応 |
|--|--|--|
| iOS | 26.1 | iPhone、iPad |
| macOS | 26.1 | Mac |
| visionOS | 26.1 | Vision Pro |

## 📦 バージョン情報
- **バージョン**: 1.0
- **作成日**: 2025年11月21日
- **最終更新**: 2026年5月30日

## 🤝 貢献ガイド

このプロジェクトへの貢献を歓迎します。以下のステップで参加できます:

1. フォークする
2. フィーチャーブランチを作成: `git checkout -b feature/amazing-feature`
3. 変更をコミット: `git commit -m 'Add amazing feature'`
4. ブランチにプッシュ: `git push origin feature/amazing-feature`
5. Pull Request を作成

### 貢献時の注意
- コードはテストを含めて提出してください
- SwiftUI ベストプラクティスに従ってください
- Xcode の警告がないか確認してください

## 📝 コミット規約
- ✨ Feature: 新機能の追加
- 🐛 Fix: バグ修正
- 📚 Docs: ドキュメント更新
- 🎨 Style: コードスタイル改善
- ♻️ Refactor: リファクタリング
- ✅ Test: テスト追加・修正
- 🔒 Security: セキュリティ改善

例: `✨ Add search history feature`

## 📄 ライセンス
このプロジェクトはオープンソースプロジェクトです。詳細は LICENSE ファイルを参照してください。

## 🐛 バグ報告・機能要望

問題が見つかったり、機能の提案がある場合は [Issues](https://github.com/VIUK-XV/VIUK-one/issues) からお知らせください。

### バグ報告テンプレート
```
## 説明
（バグの説明）

## 再現手順
1.
2.
3.

## 期待される動作
（本来の動作）

## 実際の動作
（実際の動作）

## 環境
- デバイス: 
- iOS/macOS バージョン: 
- Xcode バージョン: 
```

## 👨‍💻 サポート

質問や技術的なサポートが必要な場合は、以下の方法で連絡できます:
- GitHub Issues で質問を投稿
- Pull Request でコードレビューをリクエスト

## 🎯 今後の開発計画

- [ ] 検索機能の実装
- [ ] コンテンツフィルタリングエンジンの統合
- [ ] ペアレンタルコントロール機能
- [ ] 検索履歴と統計情報の表示
- [ ] ダークモード完全対応
- [ ] 多言語サポート
- [ ] オフラインモード
- [ ] クラウド同期機能

## 📞 連絡先

- **GitHub**: [@VIUK-XV](https://github.com/VIUK-XV)
- **リポジトリ**: [VIUK-XV/VIUK-one](https://github.com/VIUK-XV/VIUK-one)

---

**最終更新**: 2026年5月30日
**スター**: ⭐ このプロジェクトが役立つ場合は、ぜひスターをお願いします！
