/**
 * Grok 视频生成器
 *
 * grok-imagine-1.0-video 通过 OpenAI chat completions 接口生成视频，
 * 返回视频 URL 包含在 content 字段中（流式或非流式均支持）。
 *
 * 接口格式：POST /v1/chat/completions
 * 响应：content 字段包含 video URL（形如 https://.../*.mp4 或 <video src="...">）
 */

import { BaseVideoGenerator, type GenerateResult, type VideoGenerateParams } from '../base'
import { getProviderConfig } from '@/lib/api-config'

/**
 * 从 chat completions 响应 content 中提取视频 URL
 * 支持：
 * - <source src="..."> HTML 标签（网关实际返回格式）
 * - <video src="..."> HTML 标签
 * - 直接 https URL（含 .mp4/.webm/.mov 扩展名）
 * - 任意 https URL
 */
function extractVideoUrl(content: string): string | null {
    // 优先：<source ... src="..."> 标签（网关实际返回格式）
    const sourceMatch = content.match(/<source[^>]+src="([^"]+)"/i)
    if (sourceMatch) return sourceMatch[1]

    // <video ... src="..."> 标签
    const videoSrcMatch = content.match(/<video[^>]+src="([^"]+)"/i)
    if (videoSrcMatch) return videoSrcMatch[1]

    // 直接是一个视频 URL
    const directUrl = content.trim()
    if (/^https?:\/\/\S+\.(mp4|webm|mov)/i.test(directUrl)) return directUrl

    // 任意 https URL（兜底）
    const urlMatch = content.match(/https?:\/\/[^\s"'<>]+/i)
    if (urlMatch) return urlMatch[0]

    return null
}


export class GrokVideoGenerator extends BaseVideoGenerator {
    private readonly providerId: string

    constructor(providerId: string) {
        super()
        this.providerId = providerId
    }

    protected async doGenerate(params: VideoGenerateParams): Promise<GenerateResult> {
        const { userId, prompt = '' } = params
        const config = await getProviderConfig(userId, this.providerId)
        if (!config.baseUrl) {
            throw new Error(`PROVIDER_BASE_URL_MISSING: ${config.id}`)
        }
        if (!prompt.trim()) {
            throw new Error('GROK_VIDEO_PROMPT_REQUIRED')
        }

        const baseUrl = config.baseUrl.replace(/\/+$/, '')
        const url = `${baseUrl}/v1/chat/completions`

        // grok-imagine-1.0-video 通过 chat/completions 接口提交视频生成
        // 使用非流式模式，等待视频 URL 返回
        const response = await fetch(url, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                Authorization: `Bearer ${config.apiKey}`,
            },
            body: JSON.stringify({
                model: 'grok-imagine-1.0-video',
                messages: [{ role: 'user', content: prompt.trim() }],
                stream: false,
            }),
            // grok 视频生成需要较长时间，超时设置 5 分钟
        })

        if (!response.ok) {
            const text = await response.text().catch(() => '')
            throw new Error(`GROK_VIDEO_CREATE_FAILED: ${response.status} ${text.slice(0, 300)}`)
        }

        const data = await response.json() as Record<string, unknown>

        // 从 choices[0].message.content 中提取视频 URL
        const choices = Array.isArray(data.choices) ? data.choices : []
        const message = (choices[0] as Record<string, unknown> | undefined)?.message
        const content = typeof (message as Record<string, unknown> | undefined)?.content === 'string'
            ? ((message as Record<string, unknown>).content as string)
            : ''

        if (!content) {
            throw new Error(`GROK_VIDEO_EMPTY_RESPONSE: ${JSON.stringify(data).slice(0, 300)}`)
        }

        const videoUrl = extractVideoUrl(content)
        if (!videoUrl) {
            throw new Error(`GROK_VIDEO_URL_NOT_FOUND: content="${content.slice(0, 300)}"`)
        }

        // 直接返回 URL，同步完成（无需异步轮询）
        return {
            success: true,
            async: false,
            videoUrl,
        }
    }
}
