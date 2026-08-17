//! 外接 LLM API 润色（OpenAI 兼容 /chat/completions）。
//!
//! 转写完成后把文本分段送 LLM 重写，提示词约束「仅去语气词/口癖/重复，
//! 不改事实」。API 配置（URL/Key/模型）存设置，由用户自备服务
//! （DeepSeek/Qwen/OpenAI/本地 llama-server 等任何 OpenAI 兼容端点）。

use crate::settings::Settings;
use serde_json::json;

const SYSTEM_PROMPT: &str = "你是中文口语转写的润色助手。任务：去除语气助词（嗯、呃、哦等独立语气词）、口癖和结巴重复（如「我我我」→「我」、「这是这是」→「这是」），使文字通顺流畅。严格约束：不增删事实信息、不改变含义、不改数字和专有名词、保留说话人分段与换行、不添加任何解释。直接输出润色后的文本。";

/// 每段字符预算（中文 ≈ 1 token/字，1500 字/段在常见上下文限制内稳妥）。
const CHUNK_CHARS: usize = 1500;

/// 用外接 LLM 润色全文。失败时返回 Err（调用方保留原文并提示）。
pub fn polish_text(text: &str, settings: &Settings) -> Result<String, String> {
    if !settings.llm_polish || settings.llm_url.is_empty() {
        return Ok(text.to_string());
    }
    let chunks = split_chunks(text, CHUNK_CHARS);
    let mut out = String::with_capacity(text.len());
    for (i, chunk) in chunks.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        let polished = call_api(chunk, settings)?;
        out.push_str(polished.trim());
    }
    Ok(out)
}

fn split_chunks(text: &str, budget: usize) -> Vec<&str> {
    let mut chunks = Vec::new();
    let mut start = 0;
    let mut count = 0;
    for (idx, _) in text.char_indices() {
        count += 1;
        if count >= budget {
            // 在预算附近的句读处切（找不到就直接切）
            let cut = text[idx..]
                .char_indices()
                .take(60)
                .find(|(_, c)| "。？！\n".contains(*c))
                .map(|(i, c)| idx + i + c.len_utf8())
                .unwrap_or(idx);
            chunks.push(&text[start..cut]);
            start = cut;
            count = 0;
        }
    }
    if start < text.len() {
        chunks.push(&text[start..]);
    }
    if chunks.is_empty() {
        chunks.push("");
    }
    chunks
}

fn call_api(chunk: &str, settings: &Settings) -> Result<String, String> {
    let url = format!("{}/chat/completions", settings.llm_url.trim_end_matches('/'));
    let body = json!({
        "model": settings.llm_model,
        "temperature": 0.1,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": chunk},
        ],
    });
    // 代理设置与模型下载共享（settings.proxy：http/https/socks5/socks5h）
    let proxy = settings.proxy.trim().to_string();
    let mut builder = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(300));
    if !proxy.is_empty() {
        let parsed = reqwest::Proxy::all(&proxy).map_err(|e| format!("代理设置无效（{proxy}）：{e}"))?;
        builder = builder.proxy(parsed);
    }
    let client = builder.build().map_err(|e| format!("HTTP 客户端构建失败：{e}"))?;
    let resp = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", settings.llm_key))
        .json(&body)
        .send()
        .map_err(|e| format!("润色请求失败：{e}"))?;
    if !resp.status().is_success() {
        return Err(format!("润色 API 返回 {}：{}", resp.status(), resp.text().unwrap_or_default()));
    }
    let v: serde_json::Value = resp.json().map_err(|e| format!("润色响应解析失败：{e}"))?;
    v["choices"][0]["message"]["content"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "润色响应缺 choices[0].message.content".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunks_respect_budget_and_cut_at_sentence() {
        let text = "哈。".repeat(2000); // 4000 字，每 2 字一句
        let chunks = split_chunks(&text, 1500);
        assert!(chunks.len() >= 2);
        assert!(chunks.iter().all(|c| c.chars().count() <= 1560));
        assert!(chunks.iter().all(|c| c.ends_with('。')));
        assert_eq!(chunks.concat(), text);
    }

    #[test]
    fn passthrough_when_disabled() {
        let s = Settings::default();
        assert_eq!(polish_text("嗯，测试", &s).unwrap(), "嗯，测试");
    }
}
