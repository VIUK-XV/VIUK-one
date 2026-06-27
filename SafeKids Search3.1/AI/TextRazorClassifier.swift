/*
仕様:
- 役割: 外部テキスト分類APIを呼び出し、危険カテゴリ検出の補助結果を返す。
- 主な型: `TextRazorClassifier`, `ClassificationResult`, `Category`, `TextRazorError`.
- 編集ポイント: 分類APIの差し替え、タイムアウト、危険語判定ルールを変えるときに触る。
*/
//
// TextRazorClassifier.swift
// SafeKids Search
//
// Created by 日隈奏斗 on 2025/11/10.
//

import Foundation

struct TextRazorClassifier {
    private let apiKey: String
    private let endpoint = "https://api.textrazor.com/"
    
    // タイムアウト設定
    private let timeout: TimeInterval = 10.0

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// TextRazor APIでテキストを分類
    /// - Parameters:
    ///   - text: 分析するテキスト
    ///   - completion: 結果を返すクロージャ
    func classifyPageContent(text: String, completion: @escaping (Result<ClassificationResult, Error>) -> Void) {
        // 空テキストチェック
        guard !text.isEmpty else {
            completion(.failure(TextRazorError.emptyText))
            return
        }
        
        // テキスト長制限（200,000文字まで）
        let processedText = String(text.prefix(200_000))
        
        // APIキー確認
        guard !apiKey.isEmpty else {
            completion(.failure(TextRazorError.invalidAPIKey))
            return
        }
        
        // URLリクエスト作成
        guard let url = URL(string: endpoint) else {
            completion(.failure(TextRazorError.invalidEndpoint))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-TextRazor-Key")
        request.timeoutInterval = timeout
        
        // リクエストボディ作成
        let encodedText = processedText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let bodyString = "text=\(encodedText)&extractors=categories"
        request.httpBody = bodyString.data(using: .utf8)
        
        // API呼び出し
        URLSession.shared.dataTask(with: request) { data, response, error in
            // エラーチェック
            if let error = error {
                completion(.failure(error))
                return
            }
            
            // HTTPレスポンスチェック
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(TextRazorError.invalidResponse))
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(TextRazorError.httpError(statusCode: httpResponse.statusCode)))
                return
            }
            
            // データチェック
            guard let data = data else {
                completion(.failure(TextRazorError.noData))
                return
            }
            
            // JSONパース
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let response = json["response"] as? [String: Any] {
                    
                    // カテゴリ抽出
                    if let categories = response["categories"] as? [[String: Any]] {
                        var results: [Category] = []
                        
                        for categoryData in categories {
                            if let label = categoryData["label"] as? String,
                               let score = categoryData["score"] as? Double {
                                let categoryId = categoryData["categoryId"] as? String
                                results.append(Category(
                                    label: label,
                                    score: score,
                                    categoryId: categoryId
                                ))
                            }
                        }
                        
                        let classificationResult = ClassificationResult(
                            categories: results,
                            language: response["language"] as? String
                        )
                        completion(.success(classificationResult))
                    } else {
                        // カテゴリが見つからない場合
                        completion(.success(ClassificationResult(categories: [], language: nil)))
                    }
                } else {
                    completion(.failure(TextRazorError.parseError))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - Data Models

/// 分類結果
struct ClassificationResult {
    let categories: [Category]
    let language: String?
    
    func dangerAssessment() -> (isDangerous: Bool, detectedCategories: [String]) {
        let dangerousKeywords = [
            "adult", "pornography", "sexual", "gambling", "violence",
            "drugs", "weapons", "hate", "illegal", "porn", "xxx",
            "scam", "phishing", "malware", "fraud", "casino"
        ]
        
        let detected = categories.filter { category in
            dangerousKeywords.contains { keyword in
                category.label.lowercased().contains(keyword)
            }
        }
        
        return (
            isDangerous: !detected.isEmpty,
            detectedCategories: detected.map { $0.label }
        )
    }

    func containsDangerousContent() -> (isDangerous: Bool, detectedCategories: [String]) {
        dangerAssessment()
    }
    
    // ← ここに追加
    func getTopCategory() -> Category? {
        return categories.sorted { $0.score > $1.score }.first
    }
}


/// カテゴリ情報
struct Category {
    let label: String
    let score: Double
    let categoryId: String?
}

// MARK: - Error Types

enum TextRazorError: LocalizedError {
    case emptyText
    case invalidAPIKey
    case invalidEndpoint
    case invalidResponse
    case noData
    case parseError
    case httpError(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "テキストが空です"
        case .invalidAPIKey:
            return "APIキーが設定されていません"
        case .invalidEndpoint:
            return "エンドポイントURLが無効です"
        case .invalidResponse:
            return "無効なレスポンスです"
        case .noData:
            return "データが取得できませんでした"
        case .parseError:
            return "JSONのパースに失敗しました"
        case .httpError(let statusCode):
            return "HTTPエラー: \(statusCode)"
        }
    }
}
