/**
 * What `require("config.review_comments").snapshot()` answers over nvim's RPC
 * socket: the queue's payload, the ids it holds, and where that nvim runs.
 */
export type NvimReviewSnapshot = {
  count: number
  ids: number[]
  text?: string
  cwd: string
  workspace?: string
}

declare module 'claude-code' {
  interface PluginState {
    'nvim-review': {
      /** Comments queued across the nvims that belong to this session. */
      queued: number
    }
  }
}
