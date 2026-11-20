pub(super) fn translate(source: &str) -> &str {
    match source {
        " · 快速" => " · Fast",
        "### 推理\n" => "### Reasoning\n",
        "### 附件\n" => "### Attachments\n",
        "%Y年%-m月%-d日 %H:%M:%S" => "%b %-d, %Y %H:%M:%S",
        "%m月%d日 %H:%M" => "%b %d, %H:%M",
        "1 个问题" => "1 question",
        "Alt + ↑ ↓ 切换问题 · Ctrl + Enter 提交" => {
            "Alt + ↑ ↓ Switch questions · Ctrl + Enter Submit"
        }
        "Codex 订阅额度" => "Codex subscription limits",
        "Codex 额度" => "Codex limits",
        "Ctrl+K 或 Ctrl+P" => "Ctrl+K or Ctrl+P",
        "Hermes Lite · 通知预览" => "Hermes Lite · Notification preview",
        "Hermes 想确认" => "Hermes has a question",
        "Shift + 单击置顶 · 拖动排序" => "Shift-click to pin · Drag to reorder",
        "[图片]" => "[Image]",
        "↑ ↓ 移动 · Enter 选择" => "↑ ↓ Move · Enter Select",
        "⌘K 或 ⌘P" => "⌘K or ⌘P",
        "⌥ ↑ ↓ 切换问题 · ⌘ Enter 提交" => "⌥ ↑ ↓ Switch questions · ⌘ Enter Submit",
        "一月" => "January",
        "一次最多发送 10 张图片" => "You can send up to 10 images at once",
        "一次最多重新发送 10 张图片" => "You can resend up to 10 images at once",
        "七月" => "July",
        "三月" => "March",
        "上一个匹配" => "Previous match",
        "上一张（←）" => "Previous image (←)",
        "上一条发送尚未确认，请先处理待确认消息" => {
            "The previous message is awaiting confirmation. Resolve it before sending again."
        }
        "上一条消息待确认" => "The previous message is awaiting confirmation",
        "上一级目录" => "Go up one directory",
        "上传文件或图片…" => "Upload files or images…",
        "上传附件中" => "Uploading attachments",
        "上周" => "Last week",
        "上次执行" => "Last run",
        "上级目录" => "Parent directory",
        "下一个匹配" => "Next match",
        "下一张（→）" => "Next image (→)",
        "下一轮使用此推理强度" => "Use this effort level on the next turn",
        "下一轮使用此模型" => "Use this model on the next turn",
        "下次执行" => "Next run",
        "下载" => "Download",
        "下载不完整，请重试" => "Incomplete download. Try again.",
        "下载中" => "Downloading",
        "下载原图" => "Download original",
        "中" => "Medium",
        "为这个档案设置人格和行为指令。" => {
            "Set this profile's personality and behavior."
        }
        "九月" => "September",
        "二月" => "February",
        "五月" => "May",
        "仅显示文件开头" => "Showing the beginning of the file",
        "仅本地保存" => "Save locally only",
        "今天早些时候" => "Earlier today",
        "以往任务" => "Previous tasks",
        "任务" => "Tasks",
        "任务名称" => "Task name",
        "会话" => "Conversations",
        "会话仍在恢复，请稍后再试" => {
            "The conversation is still loading. Try again shortly."
        }
        "会话侧栏" => "Conversation sidebar",
        "会话内查找" => "Find in conversation",
        "会话在读取历史期间切换了续接记录" => {
            "The continuation changed while loading history"
        }
        "会话已更新。可以复制编辑内容，再重新打开这条消息。" => {
            "The conversation changed. Copy your edits and reopen the message to continue."
        }
        "会话已更新，请重新发送图片" => {
            "The conversation changed. Send the images again."
        }
        "会话已更新，请重新发送附件" => {
            "The conversation changed. Send the attachment again."
        }
        "会话已更新，请重新读取工具结果" => {
            "The conversation changed. Reload the tool result."
        }
        "会话操作" => "Conversation actions",
        "会话更新待确认" => "Conversation update awaiting confirmation",
        "会话标题" => "Conversation title",
        "会话正在运行，请稍后重试" => "The conversation is busy. Try again shortly.",
        "会话状态已变化，请重试" => "The conversation state changed. Try again.",
        "会话记录超过 32 MB，可使用网关管理界面导出" => {
            "Conversation history exceeds 32 MB. Export it from the gateway dashboard."
        }
        "低" => "Low",
        "使用 Profile 默认模型" => "Use profile default model",
        "例如 0 9 * * 1-5 或 every 30m" => "For example, 0 9 * * 1-5 or every 30m",
        "例如 research" => "For example, research",
        "侧栏宽度" => "Sidebar width",
        "侧栏磨砂" => "Frosted sidebar",
        "保存 SOUL.md 失败" => "Could not save SOUL.md",
        "保存 SOUL.md" => "Save SOUL.md",
        "保存" => "Save",
        "保存中…" => "Saving…",
        "保存到本机" => "Save to this device",
        "保存原图" => "Save original image",
        "保存后移至队尾" => "Move to end of queue after saving",
        "保存对话框已关闭" => "The save dialog was closed",
        "保存并重发 · Ctrl+Enter" => "Save and resend · Ctrl+Enter",
        "保存并重发 · ⌘+Enter" => "Save and resend · ⌘+Enter",
        "保存并重连" => "Save and reconnect",
        "保存当前会话" => "Save this conversation",
        "信息" => "Information",
        "停止" => "Stop",
        "停止当前回复" => "Stop the current reply",
        "允许一次" => "Allow once",
        "全部关闭" => "Close all tabs",
        "八月" => "August",
        "六月" => "June",
        "关闭" => "Close",
        "关闭其他" => "Close other tabs",
        "关闭右侧" => "Close tabs to the right",
        "关闭后，启动时进入一个空白草稿。" => {
            "When disabled, the app opens a blank draft."
        }
        "关闭命令结果" => "Close command result",
        "关闭定时任务" => "Close scheduled tasks",
        "关闭弹窗" => "Close pop-up",
        "关闭查找" => "Close find",
        "关闭标签" => "Close tab",
        "关闭设置" => "Close settings",
        "关闭配置档案" => "Close profiles",
        "其他（输入你的答案）" => "Other (enter your answer)",
        "写下这个配置档案的人格与行为指令" => {
            "Describe this profile's personality and behavior"
        }
        "分叉" => "Fork",
        "分支" => "Branch",
        "切换 Profile" => "Switch profile",
        "列出技能组合" => "List skill bundles",
        "刚刚" => "Just now",
        "创建档案" => "Create profile",
        "创建配置档案失败" => "Could not create profile",
        "删除" => "Delete",
        "删除此定时任务？" => "Delete this scheduled task?",
        "到点后要执行的内容" => "What should this task do?",
        "刷新 Profile 列表" => "Refresh profiles",
        "刷新" => "Refresh",
        "刷新变更" => "Refresh changes",
        "刷新定时任务" => "Refresh scheduled tasks",
        "刷新模型" => "Refresh models",
        "刷新目录" => "Refresh directory",
        "刷新配置档案列表" => "Refresh profiles",
        "前后切换标签" => "Switch tabs",
        "前往" => "Go to",
        "剪贴板中没有图片" => "No image on the clipboard",
        "剪贴板中的位图过大或已损坏" => "The clipboard bitmap is too large or damaged",
        "剪贴板正忙，请再粘贴一次" => "The clipboard is busy. Paste again.",
        "加入队列" => "Add to queue",
        "加载更多" => "Load more",
        "助手" => "Assistant",
        "十一月" => "November",
        "十二月" => "December",
        "十月" => "October",
        "即将执行" => "Due now",
        "历史会话" => "Conversation history",
        "历史记录没有返回工具结果" => "History did not include a tool result",
        "原消息已不在当前会话记录中" => {
            "The original message is no longer in this conversation"
        }
        "原消息已更新，无法重发这组图片" => {
            "The original message changed. Its images could not be resent."
        }
        "原消息已更新，无法重新读取原图" => {
            "The original message changed. Its images could not be reloaded."
        }
        "原消息暂不可见" => "The original message is unavailable",
        "参数" => "Arguments",
        "发送" => "Send",
        "发送（Enter）" => "Send (Enter)",
        "取消" => "Cancel",
        "取消归档" => "Unarchive",
        "取消收藏" => "Remove from favorites",
        "取消编辑 · Esc" => "Cancel edit · Esc",
        "取消置顶" => "Unpin",
        "变更" => "Changes",
        "可多选" => "Select multiple",
        "后台委派已完成" => "Delegation finished",
        "后台进程" => "Background process",
        "后台进程已完成" => "Background process finished",
        "启动时恢复上次会话" => "Restore the last conversation on startup",
        "命令" => "Commands",
        "命令与技能" => "Commands and skills",
        "命令已完成" => "Command completed",
        "品红" => "Magenta",
        "四月" => "April",
        "回到最新" => "Jump to latest",
        "回到这条提问" => "Jump to this question",
        "回复完成提醒" => "Reply notifications",
        "回复已完成" => "Reply complete",
        "回复的保存位置不唯一，请刷新会话后重试" => {
            "Multiple saved replies match. Reload the conversation and try again."
        }
        "回答问题" => "Answer questions",
        "图片大小超过 16 MB" => "Image exceeds 16 MB",
        "图片必须是普通文件" => "The image must be a regular file",
        "图片数据损坏" => "Corrupted image data",
        "图片格式无效" => "Invalid image format",
        "图片格式暂不支持" => "Unsupported image format",
        "图片消息" => "Image message",
        "图片需要重新上传" => "Upload the images again",
        "在会话内查找" => "Find in conversation",
        "在当前会话中查找" => "Search within this conversation",
        "在新对话中分支" => "Fork into a new conversation",
        "在新标签页打开" => "Open in new tab",
        "在浏览器中使用网关用户名和密码登录。登录完成后，客户端会自动连接。" => {
            "Sign in with your gateway username and password in your browser. The client connects automatically after sign-in."
        }
        "在浏览器中登录" => "Sign in with browser",
        "复制 ID" => "Copy ID",
        "复制代码" => "Copy code",
        "复制内容" => "Copy text",
        "复制原始差异" => "Copy raw diff",
        "复制原文" => "Copy original text",
        "复制完整内容" => "Copy full text",
        "复制工作区路径" => "Copy workspace path",
        "复制文件内容" => "Copy file contents",
        "复制最后一条助手回复" => "Copy the last assistant reply",
        "复制消息" => "Copy message",
        "复制自" => "Copy from",
        "复制草稿" => "Copy draft",
        "复制远程路径" => "Copy remote path",
        "复制通知原文" => "Copy original notice",
        "复制预览内容" => "Copy preview text",
        "外观" => "Appearance",
        "大" => "Large",
        "失败" => "Failed",
        "始终允许" => "Always allow",
        "子代理" => "Subagent",
        "定位会话轮次" => "Jump to a turn",
        "定位消息" => "Jump to message",
        "定时任务" => "Scheduled tasks",
        "定时任务读取失败" => "Could not load scheduled tasks",
        "审批" => "Approval",
        "审批模式" => "Approval mode",
        "审查 Git 变更" => "Review Git changes",
        "审查变更" => "Review changes",
        "审查工作区变更" => "Review workspace changes",
        "审查工作区改动" => "Review workspace changes",
        "宽" => "Wide",
        "对比上一版本" => "Compare with previous revision",
        "对话时间线" => "Conversation timeline",
        "对话背景" => "Conversation background",
        "导出 JSON" => "Export JSON",
        "导出 Markdown" => "Export Markdown",
        "导出期间会话发生变化，请重试" => {
            "The conversation changed during export. Try again."
        }
        "将当前会话分叉到新标签" => "Fork this conversation into a new tab",
        "小" => "Small",
        "展开代码块" => "Expand code block",
        "展开会话状态" => "Expand conversation status",
        "展开会话状态（有排队消息）" => "Expand conversation status (queued messages)",
        "常规" => "General",
        "界面语言" => "Interface language",
        "跟随系统" => "Follow system",
        "工作区" => "Workspace",
        "工作区引用" => "Workspace references",
        "工作区操作" => "Workspace actions",
        "工作区文件" => "Workspace files",
        "工作簿超过预览大小限制，请下载查看" => {
            "This workbook exceeds the preview size limit. Download it to view it."
        }
        "工作表内容无法解析" => "Could not parse the worksheet",
        "工具" => "Tool",
        "工具与技能" => "Tools and skills",
        "工具审批" => "Tool approval",
        "工具记录超出可读取的历史范围" => {
            "The tool record is outside the available history"
        }
        "工具调用" => "Tool call",
        "已保存" => "Saved",
        "已停用" => "Disabled",
        "已分析图片" => "Analyzed image",
        "已加载技能" => "Loaded skill",
        "已取消" => "Canceled",
        "已完成" => "Completed",
        "已归档" => "Archived",
        "已打开" => "Open tabs",
        "已搜索文件" => "Searched files",
        "已搜索网页" => "Searched the web",
        "已暂停" => "Paused",
        "已暂存" => "Staged",
        "已查看目录" => "Listed directory",
        "已登录 · 会话自动续期" => "Signed in · Renews automatically",
        "已置顶" => "Pinned",
        "已读取文件" => "Read file",
        "已超时" => "Timed out",
        "已跳过" => "Skipped",
        "已运行" => "Ran",
        "已连接" => "Connected",
        "已逾期" => "Overdue",
        "已错过" => "Missed",
        "异常" => "Error",
        "引用远程文件" => "Reference remote file",
        "引用远程文件夹" => "Reference remote folder",
        "归档" => "Archive",
        "当前会话没有运行中的后台进程或子代理" => {
            "No background processes or subagents are running in this conversation"
        }
        "当前目录没有 Git 仓库" => "There is no Git repository in this directory",
        "待发送的替换消息" => "Pending replacement message",
        "待处理提醒" => "Action required notifications",
        "待执行" => "Pending",
        "待确认" => "Awaiting confirmation",
        "待调度" => "Not scheduled",
        "快速打开" => "Quick open",
        "思考" => "Thinking",
        "恢复" => "Resume",
        "恢复原始缩放" => "Reset zoom",
        "手动" => "Manual",
        "打开会话" => "Open conversation",
        "打开设置" => "Open settings",
        "打开预览" => "Open preview",
        "执行中" => "In progress",
        "执行指令" => "Instructions",
        "执行结果待确认" => "Execution result awaiting confirmation",
        "执行记录读取失败" => "Could not load run history",
        "找不到 Hermes Agent。安装后可从本地网关连接" => {
            "Hermes Agent was not found. Install it to connect to a local gateway."
        }
        "找不到要修改的会话" => "Could not find the conversation to edit",
        "找不到这条已保存的回复，请刷新会话后重试" => {
            "The saved reply could not be found. Reload the conversation and try again."
        }
        "找不到这段会话" => "Conversation not found",
        "技能" => "Skills",
        "投递" => "Delivery",
        "投递目标" => "Delivery destination",
        "拒绝" => "Deny",
        "排队中" => "Queued",
        "推理" => "Reasoning",
        "推理已就绪" => "Inference ready",
        "推理强度" => "Reasoning effort",
        "推理未就绪" => "Inference not ready",
        "推理过程" => "Reasoning visibility",
        "推荐" => "Recommended",
        "描述你的任务，或添加文件和图片。" => {
            "Describe a task or attach files and images."
        }
        "插件命令" => "Plugin commands",
        "搜索会话" => "Search conversations",
        "搜索会话或操作…" => "Search conversations or actions…",
        "搜索模型或提供商" => "Search models or providers",
        "搜索结果" => "Search results",
        "搜索配置档案" => "Search profiles",
        "撤回" => "Withdraw",
        "收藏 书签 bookmarks" => "favorites bookmarks",
        "收藏" => "Favorites",
        "收藏模型" => "Favorite model",
        "收藏消息" => "Bookmark message",
        "收藏的消息" => "Bookmarked messages",
        "收起代码块" => "Collapse code block",
        "收起会话状态" => "Collapse conversation status",
        "放大" => "Zoom in",
        "放弃待发内容" => "Discard pending message",
        "数值越高，越能看见窗口后方的颜色。" => {
            "Increase transparency to see more of the desktop behind the window."
        }
        "文件" => "File",
        "文件夹" => "Folder",
        "文件未完整读取，请重试" => "The file was not fully read. Try again.",
        "新会话" => "New conversation",
        "新建任务" => "New task",
        "新建会话" => "New conversation",
        "新建标签" => "New tab",
        "新建档案" => "New profile",
        "新建配置档案" => "Create profile",
        "新开一个聊天标签" => "Open a new chat tab",
        "无变化，本次未唤醒智能体" => "No changes detected. The agent was not started.",
        "无差异" => "No differences",
        "无效的图片响应" => "Invalid image response",
        "无法保存下载文件" => "Could not save the downloaded file",
        "无法保存图片" => "Could not save image",
        "无法保存导出的会话" => "Could not save the conversation export",
        "无法准备会话模型切换" => "Could not prepare the model switch",
        "无法准备本地网关" => "Could not prepare the local gateway",
        "无法加载图片" => "Could not load image",
        "无法启动本地票据通道" => "Could not start the local ticket channel",
        "无法完成远程连接测试" => "Could not complete the remote connection test",
        "无法定位应用配置目录" => "Could not locate the app configuration folder",
        "无法定位截图存储目录" => "Could not locate the screenshot folder",
        "无法打开图片" => "Could not open image",
        "无法打开文件选择窗口" => "Could not open the file picker",
        "无法打开本地票据输入" => "Could not open local ticket input",
        "无法打开本地票据输出" => "Could not open local ticket output",
        "无法解码图片" => "Could not decode image",
        "无法识别剪贴板中的图片格式" => "Unrecognized clipboard image format",
        "无法读取 XLSX 工作簿" => "Could not read the XLSX workbook",
        "无法读取会话" => "Could not load the conversation",
        "无法读取会话历史" => "Could not load conversation history",
        "无法读取会话执行版本" => "Could not read conversation execution revision",
        "无法读取会话版本" => "Could not read conversation revision",
        "无法读取分叉边界" => "Could not read the fork point",
        "无法读取剪贴板中的位图" => "Could not read the bitmap from the clipboard",
        "无法读取工作区变更" => "Could not load workspace changes",
        "无法读取工作表" => "Could not read the worksheet",
        "无法读取应用配置" => "Could not read app configuration",
        "无法读取技能" => "Could not load skills",
        "无法读取文件" => "Could not read the file",
        "无法读取文件差异" => "Could not load the file diff",
        "无法读取模型列表" => "Could not load the model list",
        "无法读取远程目录" => "Could not load the remote directory",
        "无法读取配置档案，请刷新重试" => {
            "Could not load profiles. Refresh to try again."
        }
        "无法读取附件" => "Could not read the attachment",
        "无法转换图片" => "Could not convert image",
        "无法连接网关 WebSocket" => "Could not connect to the gateway WebSocket",
        "无法退出本机登录" => "Could not sign out on this device",
        "无输出" => "No output",
        "无需审批即可运行" => "Run without approval prompts",
        "无颜色" => "No color",
        "时间未知" => "Unknown time",
        "昨天" => "Yesterday",
        "显示" => "Show",
        "显示会话侧栏" => "Show conversation sidebar",
        "显示会话右侧的轮次定位刻度。" => {
            "Show turn markers on the right side of the conversation."
        }
        "显示思考过程" => "Show reasoning",
        "智能" => "Smart",
        "暂停" => "Pause",
        "暂无 SOUL.md，保存后创建。" => "No SOUL.md yet. Save to create it.",
        "暂无会话" => "No conversations",
        "暂无可复制的回复" => "No reply to copy",
        "暂无可显示的日志" => "No logs to show",
        "暂无定时任务" => "No scheduled tasks",
        "暂无归档会话" => "No archived conversations",
        "暂无执行记录" => "No runs yet",
        "暂无模型" => "No models available",
        "暂无模型选项" => "No model options available",
        "暂无消息" => "No messages yet",
        "暂无记忆" => "No memory yet",
        "暂无输出" => "No output yet",
        "暂无额度数据" => "No usage data",
        "更多操作" => "More actions",
        "更多日志" => "More logs",
        "最低" => "Minimal",
        "最大" => "Max",
        "最近会话" => "Recent conversations",
        "最近执行" => "Recent runs",
        "最近活动" => "Recent activity",
        "有未保存的编辑" => "Unsaved edits",
        "未命名会话" => "Untitled conversation",
        "未回答" => "Unanswered",
        "未就绪" => "Not ready",
        "未提交" => "Uncommitted",
        "未收到会话更新确认" => "The conversation update was not confirmed",
        "未收到保存确认，可重试这次保存" => "Save was not confirmed. You can retry.",
        "未收到分叉确认，可以通过原会话菜单重试" => {
            "The fork was not confirmed. Retry from the original conversation menu."
        }
        "未收到发送确认" => "Sending was not confirmed",
        "未收到审批模式确认" => "Approval mode was not confirmed",
        "未收到思考显示设置的确认" => "No confirmation for reasoning visibility",
        "未收到技能请求确认" => "No confirmation for the skill request",
        "未收到撤回确认" => "Withdrawal was not confirmed",
        "未收到新会话确认，草稿已保留" => {
            "The new conversation was not confirmed. Your draft was kept."
        }
        "未收到模型设置确认，可以重试" => {
            "Model settings were not confirmed. You can retry."
        }
        "未收到网关确认" => "No confirmation from the gateway",
        "未收到网关返回的命令结果" => "The gateway did not return a command result",
        "未收到附件上传确认" => "No confirmation for the attachment upload",
        "未知的推理选项" => "Unknown reasoning option",
        "未能上传附件" => "Could not upload the attachment",
        "未能创建会话" => "Could not create the conversation",
        "未能读取 SOUL.md" => "Could not load SOUL.md",
        "未连接" => "Disconnected",
        "未送达" => "Undelivered",
        "本会话允许" => "Allow for this conversation",
        "本周早些时候" => "Earlier this week",
        "本地 Hermes CLI 未返回网关信息，请更新 Hermes Agent" => {
            "The local Hermes CLI did not provide gateway details. Update Hermes Agent."
        }
        "本地票据响应与请求不匹配" => {
            "The local ticket response did not match the request"
        }
        "本地票据通道已关闭或返回无效响应" => {
            "The local ticket channel closed or returned an invalid response"
        }
        "本地票据通道返回无效响应" => {
            "The local ticket channel returned an invalid response"
        }
        "本地网关" => "Local gateway",
        "本地网关实例已变化，请重新连接" => {
            "The local gateway instance changed. Reconnect to continue."
        }
        "本地网关未返回有效票据" => "The local gateway returned an invalid ticket",
        "本地网关票据无效" => "Invalid local gateway ticket",
        "本地网关票据等待超时" => "Timed out waiting for a local gateway ticket",
        "本地网关缺少地址" => "The local gateway did not provide an address",
        "本地网关缺少实例标识" => "The local gateway did not provide an instance ID",
        "本地网关返回了不兼容的连接地址" => {
            "The local gateway returned an unsupported connection address"
        }
        "本月早些时候" => "Earlier this month",
        "本机" => "This device",
        "本次会话" => "This conversation",
        "本次会话暂无文件" => "No files in this conversation",
        "本次未唤醒智能体" => "The agent was not started for this run",
        "极高" => "Extra high",
        "查找并打开历史会话" => "Find and open a past conversation",
        "查找记忆内容" => "Find in memory",
        "查看 Codex 订阅额度" => "View Codex subscription limits",
        "查看上下文用量和压缩信息" => "Show context usage and compaction details",
        "查看会话和模型状态" => "Show conversation and model status",
        "查看大图" => "View full image",
        "查看工作区差异" => "View workspace diff",
        "查看工作区文件" => "Browse workspace files",
        "查看已归档会话" => "Show archived conversations",
        "查看当前 Profile" => "Show the current profile",
        "查看当前会话的后台工作" => "Show background work in this conversation",
        "查看当前命令权限" => "Show current command permissions",
        "查看待审核的技能" => "View skills pending review",
        "查看待审核的记忆" => "View memories pending review",
        "查看或选择会话人格" => "View or choose the conversation persona",
        "查看用量和限额" => "Show usage and limits",
        "查看网关版本" => "Show the gateway version",
        "查看自动化建议" => "View automation suggestions",
        "标准" => "Standard",
        "标记为已读" => "Mark as read",
        "标记为未读" => "Mark as unread",
        "档案名称" => "Profile name",
        "模型" => "Model",
        "模型选项" => "Model options",
        "橙色" => "Orange",
        "正在保存…" => "Saving…",
        "正在准备…" => "Preparing…",
        "正在准备本地网关" => "Preparing the local gateway",
        "正在分析图片" => "Analyzing image",
        "正在创建…" => "Creating…",
        "正在加载图片…" => "Loading image…",
        "正在加载技能" => "Loading skill",
        "正在发送" => "Sending",
        "正在定位会话工作目录…" => "Locating the conversation's working directory…",
        "正在应用会话设置" => "Applying conversation settings",
        "正在恢复会话…" => "Restoring conversation…",
        "正在恢复会话目录…" => "Restoring conversation directory…",
        "正在提交…" => "Submitting…",
        "正在搜索历史会话…" => "Searching conversation history…",
        "正在搜索文件" => "Searching files",
        "正在搜索网页" => "Searching the web",
        "正在整理会话文件…" => "Gathering conversation files…",
        "正在更新" => "Updating",
        "正在更新会话…" => "Updating conversation…",
        "正在查看目录" => "Listing directory",
        "正在测试" => "Testing",
        "正在粘贴图片" => "Pasting image",
        "正在读取 Git 变更…" => "Loading Git changes…",
        "正在读取 SOUL.md…" => "Loading SOUL.md…",
        "正在读取…" => "Loading…",
        "正在读取会话…" => "Loading conversations…",
        "正在读取历史…" => "Loading history…",
        "正在读取原图…" => "Loading original images…",
        "正在读取定时任务…" => "Loading scheduled tasks…",
        "正在读取工作表…" => "Loading worksheet…",
        "正在读取工具结果…" => "Loading tool result…",
        "正在读取差异…" => "Loading diff…",
        "正在读取执行记录…" => "Loading run history…",
        "正在读取技能…" => "Loading skills…",
        "正在读取文件" => "Reading file",
        "正在读取文件…" => "Loading file…",
        "正在读取模型列表…" => "Loading models…",
        "正在读取目录…" => "Loading directory…",
        "正在读取配置档案…" => "Loading profiles…",
        "正在运行" => "Running",
        "正在连接" => "Connecting",
        "正在重连" => "Reconnecting",
        "此命令不需要参数" => "This command takes no arguments",
        "此命令只支持菜单中列出的选项" => {
            "This command only accepts the options shown in the menu"
        }
        "此工作簿没有可预览的工作表" => "This workbook has no worksheets to preview",
        "此工作表为空" => "This worksheet is empty",
        "此文件没有文本差异" => "This file has no text diff",
        "此文件类型没有文本预览" => "There is no text preview for this file type",
        "此文件超过预览大小限制，请下载查看" => {
            "This file exceeds the preview size limit. Download it to view it."
        }
        "此模型没有可调选项" => "This model has no adjustable options",
        "此目录为空" => "This directory is empty",
        "没有匹配的会话" => "No matching conversations",
        "没有匹配的会话或操作" => "No matching conversations or actions",
        "没有匹配的内容" => "No matches",
        "没有匹配的档案" => "No matching profiles",
        "没有匹配的模型" => "No matching models",
        "没有可用的保存目录" => "No save folder available",
        "没有可用的导出目录" => "No export folder available",
        "没有可用的工作区目录" => "No workspace directory available",
        "没有可选技能" => "No skills available",
        "测试远程" => "Test connection",
        "浏览会话和快捷操作" => "Browse conversations and quick actions",
        "浏览工作区文件" => "Browse workspace files",
        "浏览斜杠命令和技能" => "Browse slash commands and skills",
        "消息字号" => "Message text size",
        "消息已开始发送，无法保存这次编辑" => {
            "This message has started sending. The edit could not be saved."
        }
        "消息平台" => "Messaging platforms",
        "添加附件" => "Add attachment",
        "添加附件或引用" => "Add attachment or reference",
        "清除搜索" => "Clear search",
        "源码" => "Source",
        "版本未知" => "Unknown version",
        "特大" => "Extra large",
        "玫瑰色" => "Rose",
        "现在执行此定时任务？" => "Run this scheduled task now?",
        "用户" => "User",
        "用户名和密码" => "Username and password",
        "用户消息" => "User message",
        "留空时沿用此 URL 已保存的令牌。" => {
            "Leave blank to use the token saved for this URL."
        }
        "登录已超时，请重新连接" => "Sign-in timed out. Reconnect to try again.",
        "登录成功，可以返回 Hermes Lite。" => "Signed in. You can return to Hermes Lite.",
        "登录未获授权" => "Sign-in was not authorized",
        "登录窗口已关闭" => "Sign-in window closed",
        "登录远程网关" => "Sign in to remote gateway",
        "目录" => "Outline",
        "确认中断" => "Confirm interruption",
        "确认并继续" => "Confirm and continue",
        "确认模型切换" => "Confirm model switch",
        "磨砂透明度" => "Sidebar transparency",
        "稍后" => "Later",
        "空白档案" => "Blank profile",
        "窗口与布局" => "Window and layout",
        "窗口在后台时发送桌面通知。" => {
            "Show desktop notifications when the window is in the background."
        }
        "立即执行" => "Run now",
        "等待你回答" => "Waiting for your answer",
        "等待你审批" => "Waiting for your approval",
        "等待回答" => "Awaiting answer",
        "等待审批" => "Awaiting approval",
        "等待本地票据通道超时" => "Timed out waiting for the local ticket channel",
        "等待本地网关就绪超时" => "Timed out waiting for the local gateway",
        "等待登录" => "Waiting for sign-in",
        "等待网关就绪超时" => "Timed out waiting for the gateway",
        "管理定时任务" => "Manage scheduled tasks",
        "管理当前 Profile 的定时任务" => "Manage scheduled tasks for the current profile",
        "管理网关…" => "Manage gateway…",
        "管理配置档案…" => "Manage profiles…",
        "粘贴剪贴板图片" => "Paste image from clipboard",
        "系统" => "System",
        "紧凑" => "Compact",
        "紫色" => "Purple",
        "红色" => "Red",
        "结果" => "Result",
        "给 Hermes 一个任务" => "Give Hermes a task",
        "继续" => "Continue",
        "绿色" => "Green",
        "编辑" => "Edit",
        "编辑任务" => "Edit task",
        "编辑排队消息" => "Edit queued message",
        "编辑消息" => "Edit message",
        "缩小" => "Zoom out",
        "网关不支持切换到此模型标识" => "The gateway cannot switch to this model ID",
        "网关在协商客户端能力时断开" => {
            "The gateway disconnected during capability negotiation"
        }
        "网关在就绪前断开" => "The gateway disconnected before it was ready",
        "网关地址无效" => "Invalid gateway address",
        "网关已离线，连接后可重试分叉" => {
            "The gateway is offline. Reconnect to retry the fork."
        }
        "网关报告会话存储已损坏" => {
            "The gateway reported a corrupted conversation store"
        }
        "网关拒绝了此认证" => "The gateway rejected authentication",
        "网关拒绝了此认证，请检查访问令牌或登录状态" => {
            "The gateway rejected authentication. Check the access token or sign-in status."
        }
        "网关拒绝了登录凭据，请重新登录" => {
            "The gateway rejected the credentials. Sign in again."
        }
        "网关搜索暂不可用" => "Gateway search is unavailable",
        "网关无法读取此目录" => "The gateway cannot read this directory",
        "网关暂无可用额度数据" => "The gateway has no available usage data",
        "网关未提供分叉所需的会话版本" => {
            "The gateway did not provide a revision for the fork"
        }
        "网关未提供该档案的目录" => {
            "The gateway did not provide this profile's directory"
        }
        "网关未确认保存 SOUL.md" => "The gateway did not confirm saving SOUL.md",
        "网关未确认创建配置档案" => "The gateway did not confirm profile creation",
        "网关未运行" => "Gateway stopped",
        "网关未返回分叉会话标识，可重试" => {
            "The gateway did not return a forked conversation ID. You can retry."
        }
        "网关未返回原图路径" => "The gateway did not return the original image path",
        "网关未返回发送确认" => "The gateway did not confirm sending",
        "网关未返回可发送的技能请求" => {
            "The gateway did not return a skill request to send"
        }
        "网关未返回可用的原图路径" => {
            "The gateway did not return a usable path to the original image"
        }
        "网关未返回可用的图片引用" => {
            "The gateway did not return a usable image reference"
        }
        "网关未返回可预览的文本" => "The gateway did not return text for preview",
        "网关未返回回复的保存位置" => {
            "The gateway did not return the saved reply location"
        }
        "网关未返回支持的图片" => "The gateway did not return a supported image",
        "网关未返回支持的图片格式" => {
            "The gateway did not return a supported image format"
        }
        "网关未返回有效工作区变更" => {
            "The gateway did not return valid workspace changes"
        }
        "网关未返回有效差异" => "The gateway did not return a valid diff",
        "网关未返回有效的提交标识" => "The gateway did not return a valid commit ID",
        "网关未返回有效目录" => "The gateway did not return a valid directory",
        "网关未返回模型列表" => "The gateway did not return a model list",
        "网关未返回记忆原文" => "The gateway did not return the memory text",
        "网关未返回连接票据" => "The gateway did not return a connection ticket",
        "网关未返回附件引用" => "The gateway did not return an attachment reference",
        "网关未连接" => "Gateway disconnected",
        "网关没有提供工作区目录" => "The gateway did not provide a workspace directory",
        "网关状态" => "Gateway status",
        "网关要求确认这次模型切换。" => {
            "The gateway requires confirmation to switch models."
        }
        "网关设置" => "Gateway settings",
        "网关请求失败" => "Gateway request failed",
        "网关运行中" => "Gateway running",
        "网关返回了无效的执行记录" => {
            "The gateway returned an invalid execution record"
        }
        "网关返回了无法读取的 SOUL.md" => "The gateway returned an unreadable SOUL.md",
        "网关返回了无法读取的会话列表" => {
            "The gateway returned an unreadable conversation list"
        }
        "网关返回了无法读取的会话搜索结果" => {
            "The gateway returned unreadable search results"
        }
        "网关返回了无法读取的会话记录" => {
            "The gateway returned an unreadable conversation record"
        }
        "网关返回的历史分页位置不一致" => {
            "The gateway returned an unexpected history offset"
        }
        "网关返回的历史所属 Profile 不一致" => {
            "The gateway returned history for a different profile"
        }
        "网关连接" => "Gateway connection",
        "网关连接地址无效" => "Invalid gateway connection address",
        "网关连接超时" => "Gateway connection timed out",
        "网关重复返回同一页历史" => "The gateway returned a duplicate history page",
        "网关重复返回同一页历史，请重新导出" => {
            "The gateway returned the same history page again. Retry the export."
        }
        "置顶" => "Pin",
        "翡翠绿" => "Emerald",
        "聊天显示" => "Chat appearance",
        "脚本" => "Script",
        "脚本运行" => "Script run",
        "自动评估操作，必要时询问" => {
            "Assess actions automatically and ask when needed"
        }
        "自定义命令" => "Custom commands",
        "草稿" => "Draft",
        "蓝色" => "Blue",
        "解除待确认" => "Clear pending confirmation",
        "计划" => "Schedule",
        "订阅用量" => "Subscription usage",
        "认证方式" => "Authentication",
        "让窗口后方的画面轻微透出。" => "Let the desktop show through the sidebar.",
        "记忆文件超过网关的预览上限" => {
            "The memory file exceeds the gateway preview limit"
        }
        "设置" => "Settings",
        "设置推理强度" => "Set reasoning effort",
        "设置推理强度和思考显示" => "Set reasoning effort and visibility",
        "设置本机如何显示会话中的推理记录。" => {
            "Choose how reasoning records appear on this device."
        }
        "访问令牌" => "Access token",
        "该网关使用访问令牌，请切换认证方式" => {
            "This gateway uses an access token. Change the authentication method."
        }
        "请先在浏览器完成网关登录" => "Finish gateway sign-in in your browser",
        "请先打开一个会话" => "Open a conversation first",
        "请填写任务名称、计划和执行指令" => {
            "Enter a task name, schedule, and instructions"
        }
        "请用小写字母或数字开头，最多 64 个字符，可包含短横线和下划线。" => {
            "Start with a lowercase letter or number. Use up to 64 characters, including hyphens and underscores."
        }
        "请稍候" => "Please wait",
        "请等待会话恢复后再分叉" => {
            "Wait for the conversation to finish loading before forking"
        }
        "请等待会话恢复后再执行此命令" => {
            "Wait for the conversation to load before running this command"
        }
        "请至少回答一个问题。" => "Answer at least one question.",
        "请输入 /save md 或 /save json" => "Enter /save md or /save json",
        "请输入 HTTP 或 HTTPS 网关地址" => "Enter an HTTP or HTTPS gateway address",
        "请输入此地址的访问令牌" => "Enter the access token for this address",
        "请输入此网关的访问令牌" => "Enter the access token for this gateway",
        "请输入远程网关地址" => "Enter the remote gateway address",
        "请重新登录网关" => "Sign in to the gateway again",
        "读取 SOUL.md 失败" => "Could not read SOUL.md",
        "读取任务中断" => "Reading was interrupted",
        "读取会话超时" => "Timed out loading the conversation",
        "读取剪贴板图片失败" => "Could not read the clipboard image",
        "读取原图失败" => "Could not load the original image",
        "读取图片失败" => "Could not read the image",
        "读取工具结果超时" => "Timed out loading the tool result",
        "读取已保存结果" => "Load saved result",
        "调整会话侧栏宽度，双击恢复默认" => {
            "Resize the conversation sidebar. Double-click to reset."
        }
        "调整文件列表宽度，双击恢复默认" => {
            "Resize the file list. Double-click to reset."
        }
        "超强" => "Ultra",
        "跟随网关" => "Follow gateway",
        "跟随网关默认模型" => "Use gateway default model",
        "跳转到文档标题" => "Jump to a document heading",
        "跳过" => "Skip",
        "跳过全部" => "Skip all",
        "载入远端版本" => "Load remote version",
        "输入你的答案…" => "Enter your answer…",
        "输入排队消息" => "Enter queued message",
        "输入消息…" => "Type a message…",
        "输入网关令牌" => "Enter gateway token",
        "输入请求" => "Input request",
        "运行中" => "Running",
        "返回" => "Back",
        "返回会话" => "Back to conversations",
        "这个档案名称已存在。" => "A profile with this name already exists.",
        "这条收藏的消息已不在当前会话记录中" => {
            "This bookmarked message is no longer in this conversation"
        }
        "这条消息已离开队列，编辑内容仍可复制" => {
            "This message has left the queue. You can still copy your edit."
        }
        "这组图片超过网关可接收的数据大小" => {
            "These images exceed the gateway's upload limit"
        }
        "远程 URL" => "Remote URL",
        "远程文件" => "Remote file",
        "远程登录已过期，请重新登录" => "Remote sign-in expired. Sign in again.",
        "远程网关" => "Remote gateway",
        "远端 SOUL.md 已更新，当前编辑内容尚未保存。" => {
            "SOUL.md changed on the gateway. Your current edits are unsaved."
        }
        "连接与认证通过" => "Connection and authentication successful",
        "连接后在浏览器完成登录。" => {
            "Complete sign-in in your browser after connecting."
        }
        "连接已断开" => "Disconnected",
        "连接已部署的 Hermes 网关" => "Connect to a deployed Hermes gateway",
        "连接本机安装的 Hermes Agent" => "Connect to Hermes Agent installed on this device",
        "连接模式" => "Connection mode",
        "连接状态" => "Connection status",
        "连接网关" => "Connect to gateway",
        "连接网关超时" => "Timed out connecting to the gateway",
        "连接请求" => "Connection request",
        "连接远程网关后开始会话" => {
            "Connect to a remote gateway to start a conversation"
        }
        "退出本机登录" => "Sign out on this device",
        "选一个" => "Select one",
        "选择一项定时任务" => "Select a scheduled task",
        "选择对话模型" => "Choose a chat model",
        "选择技能" => "Select a skill",
        "选择文件查看差异" => "Select a file to view its diff",
        "选择文件预览" => "Select a file to preview",
        "选择模型" => "Select model",
        "选项" => "Options",
        "配置" => "Configuration",
        "配置档案" => "Profiles",
        "重命名…" => "Rename…",
        "重命名会话" => "Rename conversation",
        "重命名当前会话" => "Rename this conversation",
        "重新加载" => "Reload",
        "重新打开已关闭的标签" => "Reopen closed tab",
        "重新生成" => "Regenerate",
        "重新生成答复" => "Regenerate reply",
        "重新读取 SOUL.md" => "Reload SOUL.md",
        "重新读取" => "Reload",
        "重新连接" => "Reconnect",
        "重试" => "Retry",
        "重试下载" => "Retry download",
        "重试保存" => "Retry save",
        "重试读取结果" => "Retry loading result",
        "键盘快捷键" => "Keyboard shortcuts",
        "附件" => "Attachments",
        "附件大小超过 25 MB" => "Attachment exceeds 25 MB",
        "附件路径不可用，无法重新发送这条消息" => {
            "The attachment path is unavailable. This message could not be resent."
        }
        "隐藏" => "Hide",
        "隐藏会话侧栏" => "Hide conversation sidebar",
        "隐藏思考过程" => "Hide reasoning",
        "需要审批的操作会先询问" => "Ask before running actions that require approval",
        "青色" => "Cyan",
        "靛蓝" => "Indigo",
        "预览" => "Preview",
        "预览仅显示前段差异，可复制全文" => {
            "Preview shows the beginning of the diff. You can copy the full diff."
        }
        "预览通知" => "Preview notification",
        "高" => "High",
        "黄绿色" => "Lime",
        "黄色" => "Yellow",
        "默认" => "Default",
        "默认展开" => "Expand by default",
        "默认折叠" => "Collapse by default",
        "（估算）" => " (estimated)",
        _ => source,
    }
}
