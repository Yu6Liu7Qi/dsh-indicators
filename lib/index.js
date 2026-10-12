/**
 * DSH 菜单栏指示器 —— 宿主半边（工作状态 + 峰谷时段 + 授权提醒，合成一个插件）。
 *
 * 原来这是两个插件（dsh-work-status / dsh-peakvalley），各自写各的状态文件；
 * 合并后只有一个进程内生产者、一个状态文件、一个菜单栏 App：
 *
 *   ~/Library/Application Support/dsh-indicators/status.json
 *   {
 *     "v": 2,
 *     "pid": 51470,               // 写着它的 DSH 进程；菜单栏靠它认「换代」
 *     "updatedAt": 1760000000000, // 心跳毫秒时间戳；App 据此判断 DSH 是否仍在运行
 *     "work": {                   // ① 工作状态：谁在运行
 *       "running": 2, "total": 2,
 *       "sessions": [{ "id": "...", "status": "running", "cwd": "/..." }]
 *     },
 *     "peak": {                   // ② 峰谷时段：现在是全价还是半价；规则读不到时为 null
 *       "kind": "peak" | "off", "label": "峰" | "谷",
 *       "why": "高峰时段 09:00–12:00",
 *       "timezone": "Asia/Shanghai",
 *       "nextSwitchAt": 1760000000000, "nextKind": "peak" | "off",
 *       "rulesUpdatedAt": "2026-10-06",
 *       "sourceName": "...", "sourceUrl": "https://..."
 *     },
 *     "approval": {               // ③ 授权：此刻有几个请求在等待用户授权
 *       "pending": 1
 *     }
 *   }
 *
 * 三个来源都是「算好了写下来」，App 那边只负责画，不懂业务：
 *   - work：订阅宿主的 agent/status（idle ⇄ running）与 agent/created、agent/disposed；
 *   - peak：读 data/peak-valley.json（规则的唯一真源），按里面声明的时区算墙上时间；
 *   - approval：听 session/event 里的 approval/asked 与 approval/decided，按审批 id
 *     配对 —— 进来就 +1、出结果就 -1。（不走 approval/request：那是个 waterfall，
 *     GUI 的 answerer 会先 claim 掉请求，排在链尾的插件收不到。）
 *
 * 刷新时机：5 秒心跳（work 要它来区分「空闲」和「DSH 已退出」）+ 一个精确落在
 * 下次峰谷切换点上的定时器（跨 09:00 / 12:00 / 14:00 / 18:00 不会晚半分钟）；
 * 授权请求来得急，进出各写一次，不等心跳。
 *
 * 写文件用「临时文件 + rename」：rename 在同分区上是原子的，读者永远看不到
 * 写了一半的 JSON。
 *
 * 菜单栏 App 的生死也挂在这里：本插件加载时 spawn 它，卸载时杀掉它。于是
 * 「DSH 启动 → 指示器出现，DSH 退出 → 指示器消失」是天然成立的，不需要登录项。
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** 插件名（Cordis 行标识）。 */
const name = "indicators";

/** 依赖的宿主服务：会话/agent 注册表。 */
const inject = ["agents"];

/** 心跳间隔（毫秒）。 */
const HEARTBEAT_MS = 5000;

/** 找下一次峰谷切换时最多往后翻多少天。 */
const PEAK_LOOKAHEAD_DAYS = 15;

/** 菜单栏 App 崩溃后最多自动重拉几次，免得坏掉时无限重启刷屏。 */
const MAX_RESPAWNS = 5;

/** 本文件所在目录（`lib/`）。 */
const here = dirname(fileURLToPath(import.meta.url));

/** 峰谷规则文件路径：`lib/` 的隔壁 `data/`。 */
function rulesPath() {
	return join(here, "..", "data", "peak-valley.json");
}

/** 菜单栏 App 可执行文件路径：`lib/` 的隔壁 `menubar/`。 */
function menuBarBinaryPath() {
	return join(here, "..", "menubar", "MenuBarIndicators");
}

/**
 * 状态文件路径。
 * @returns 绝对路径；环境变量 DSH_INDICATORS_STATUS_FILE 优先。
 */
function statusFilePath() {
	const override = process.env.DSH_INDICATORS_STATUS_FILE;
	if (typeof override === "string" && override !== "") return override;
	return join(homedir(), "Library", "Application Support", "dsh-indicators", "status.json");
}

// #region 峰谷时段：规则判定
// 规则全部来自 data/peak-valley.json，这里不重复任何一条业务规则。

/** 星期缩写 → 0(周日) … 6(周六)。 */
const WEEKDAY_NUMBERS = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

/**
 * 把某时刻换算成规则时区里的墙上时间字段。
 * @param timeZone - IANA 时区名。
 * @param at - 时刻。
 * @returns `{ dateKey, year, month, day, hour, minute, weekday }`。
 */
function wallClock(timeZone, at) {
	const format = new Intl.DateTimeFormat("en-CA", {
		timeZone,
		hour12: false,
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
		weekday: "short"
	});
	const parts = {};
	for (const part of format.formatToParts(at)) parts[part.type] = part.value;
	return {
		dateKey: `${parts.year}-${parts.month}-${parts.day}`,
		year: Number(parts.year),
		month: Number(parts.month),
		day: Number(parts.day),
		// hour12:false 在午夜会给 "24"，取模归一。
		hour: Number(parts.hour) % 24,
		minute: Number(parts.minute),
		weekday: WEEKDAY_NUMBERS[parts.weekday] ?? 0
	};
}

/**
 * 某时刻该时区相对 UTC 的偏移（毫秒）。
 * @param timeZone - IANA 时区名。
 * @param at - 时刻。
 * @returns 偏移毫秒数（东八区为 +28800000）。
 */
function offsetMsAt(timeZone, at) {
	const format = new Intl.DateTimeFormat("en-US", {
		timeZone,
		hour12: false,
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
		second: "2-digit"
	});
	const parts = {};
	for (const part of format.formatToParts(at)) parts[part.type] = part.value;
	const asUtc = Date.UTC(
		Number(parts.year),
		Number(parts.month) - 1,
		Number(parts.day),
		Number(parts.hour) % 24,
		Number(parts.minute),
		Number(parts.second)
	);
	return asUtc - (at.getTime() - at.getMilliseconds());
}

/**
 * 规则时区里某个墙上时刻对应的真实瞬间。
 * @param timeZone - IANA 时区名。
 * @param year - 年。
 * @param month - 月（1-12）。
 * @param day - 日；允许越界，由 Date.UTC 归一。
 * @param hour - 时。
 * @param minute - 分。
 * @returns 毫秒时间戳。
 */
function instantOf(timeZone, year, month, day, hour, minute) {
	const guess = Date.UTC(year, month - 1, day, hour, minute);
	return guess - offsetMsAt(timeZone, new Date(guess));
}

/** "HH:MM" → 从零点起的分钟数。 */
function minutesOf(hhmm) {
	const [hour, minute] = hhmm.split(":");
	return Number(hour) * 60 + Number(minute);
}

/**
 * 命中的法定节假日区间；未命中返回 null。
 * @param rules - 规则。
 * @param wall - 墙上时间字段。
 * @returns 区间对象或 null。
 */
function holidayAt(rules, wall) {
	const table = rules.holidays?.[String(wall.year)];
	if (!Array.isArray(table)) return null;
	for (const range of table) {
		if (wall.dateKey >= range.from && wall.dateKey <= range.to) return range;
	}
	return null;
}

/**
 * 是否为调休上班日。
 * @param rules - 规则。
 * @param wall - 墙上时间字段。
 * @returns {boolean}
 */
function isMakeupWorkday(rules, wall) {
	const list = rules.makeupWorkdays?.[String(wall.year)];
	return Array.isArray(list) && list.includes(wall.dateKey);
}

/**
 * 判定某一时刻是峰还是谷。
 * @param rules - 规则。
 * @param at - 时刻。
 * @returns `{ kind, why, wall }`。
 */
function peakStatusAt(rules, at) {
	const timeZone = rules.timezone ?? "Asia/Shanghai";
	const wall = wallClock(timeZone, at);
	if (rules.peak?.excludeHolidays !== false) {
		const holiday = holidayAt(rules, wall);
		if (holiday !== null) return { kind: "off", why: `${holiday.name}假期（法定节假日全天空闲）`, wall };
	}
	if (wall.weekday === 0 || wall.weekday === 6) {
		return {
			kind: "off",
			why: isMakeupWorkday(rules, wall) ? "周末（调休上班日，规则按周一至周五，仍空闲）" : "周末",
			wall
		};
	}
	const weekdays = rules.peak?.weekdays ?? [1, 2, 3, 4, 5];
	if (!weekdays.includes(wall.weekday)) return { kind: "off", why: "非高峰工作日", wall };
	const minutes = wall.hour * 60 + wall.minute;
	for (const window of rules.peak?.windows ?? []) {
		if (minutes >= minutesOf(window[0]) && minutes < minutesOf(window[1])) {
			return { kind: "peak", why: `高峰时段 ${window[0]}–${window[1]}`, wall };
		}
	}
	return { kind: "off", why: "高峰时段之外", wall };
}

/**
 * 下一次峰谷切换。
 * @param rules - 规则。
 * @param at - 从哪一刻往后找。
 * @returns `{ at, kind }`；15 天内都不切换则返回 null。
 */
function nextPeakSwitchFrom(rules, at) {
	const timeZone = rules.timezone ?? "Asia/Shanghai";
	const current = peakStatusAt(rules, at).kind;
	const boundaries = new Set([0]);
	for (const window of rules.peak?.windows ?? []) {
		boundaries.add(minutesOf(window[0]));
		boundaries.add(minutesOf(window[1]));
	}
	const ordered = [...boundaries].sort((a, b) => a - b);
	const wall = wallClock(timeZone, at);
	for (let day = 0; day < PEAK_LOOKAHEAD_DAYS; day += 1) {
		for (const minutes of ordered) {
			const instant = instantOf(
				timeZone,
				wall.year,
				wall.month,
				wall.day + day,
				Math.floor(minutes / 60),
				minutes % 60
			);
			if (instant <= at.getTime()) continue;
			const kind = peakStatusAt(rules, new Date(instant)).kind;
			if (kind !== current) return { at: instant, kind };
		}
	}
	return null;
}
// #endregion

// #region 菜单栏 App 的启停
/**
 * 拉起菜单栏 App，并把它绑在本插件的生命周期上。
 *
 * 正常退出（从菜单里选「退出菜单栏指示器」，退出码 0）不再拉起 —— 那是用户的
 * 明确意思；只有异常退出才重启。DSH 被 SIGKILL 时会留下孤儿进程，App 那边
 * 自带三条兜底：状态文件 pid 换代就让位、宿主进程探测不到就退、连续离线就退。
 *
 * @param ctx - 宿主根上下文（只用来打日志）。
 * @param statusPath - 状态文件路径，透传给子进程保证两边读同一个文件。
 * @returns 释放函数：停掉重试计时器并杀掉子进程。
 */
function spawnMenuBar(ctx, statusPath) {
	if (process.platform !== "darwin") return () => {};
	const binary = menuBarBinaryPath();
	if (!existsSync(binary)) {
		ctx.logger?.warn?.(`dsh-indicators: 找不到菜单栏程序（${binary}），指示器不会出现`);
		return () => {};
	}

	let child = null;
	let disposed = false;
	let respawns = 0;
	let retry = null;

	/** 起一个实例，并挂上退出后的重拉逻辑。 */
	function launch() {
		if (disposed) return;
		try {
			child = spawn(binary, [], {
				stdio: "ignore",
				env: { ...process.env, DSH_INDICATORS_STATUS_FILE: statusPath }
			});
			// 子进程不能拖住宿主的事件循环。
			child.unref();
		} catch (error) {
			child = null;
			ctx.logger?.warn?.(`dsh-indicators: 启动菜单栏程序失败：${String(error)}`);
			return;
		}
		child.on("error", (error) => {
			ctx.logger?.warn?.(`dsh-indicators: 菜单栏程序出错：${String(error)}`);
		});
		child.on("exit", (code) => {
			child = null;
			if (disposed || code === 0) return;
			if (respawns >= MAX_RESPAWNS) return;
			respawns += 1;
			retry = setTimeout(launch, 2000);
		});
	}

	launch();

	return () => {
		disposed = true;
		if (retry !== null) clearTimeout(retry);
		if (child !== null && child.exitCode === null) child.kill();
	};
}
// #endregion

/**
 * 安装状态镜像。
 * @param ctx - 宿主根上下文。
 * @returns {void}
 */
function apply(ctx) {
	const path = statusFilePath();
	/** agent → { id, status, cwd } */
	const agents = new Map();
	/** 峰谷规则；读不到就为 null，此时 peak 段写 null，App 会把那项隐藏。 */
	let rules = null;
	/** 等待用户授权的请求：审批 id → 请求信息。按 id 配对，不会重复计数。 */
	const approvals = new Map();
	/** 写失败只吵一次，避免每 5 秒刷屏。 */
	let warned = false;

	/**
	 * 记录一个 agent 的当前状态。
	 * @param agent - 宿主 agent 对象。
	 * @param status - 显式状态；缺省读 agent.status。
	 * @returns {void}
	 */
	function track(agent, status) {
		if (agent === null || typeof agent !== "object") return;
		const id = agent?.session?.id ?? agent?.id;
		if (typeof id !== "string") return;
		const resolved = status ?? agent.status;
		let cwd;
		try {
			const value = agent?.session?.header?.cwd;
			if (typeof value === "string") cwd = value;
		} catch {
			cwd = undefined;
		}
		agents.set(agent, { id, status: resolved === "running" ? "running" : "idle", cwd });
	}

	/**
	 * 组出 work 段。
	 * @returns 工作状态对象。
	 */
	function workSection() {
		const sessions = [];
		for (const info of agents.values()) {
			const row = { id: info.id, status: info.status };
			if (info.cwd !== undefined) row.cwd = info.cwd;
			sessions.push(row);
		}
		// 运行中的排在前面，菜单中一眼可见。
		sessions.sort((a, b) => (a.status === b.status ? 0 : a.status === "running" ? -1 : 1));
		return {
			running: sessions.filter((row) => row.status === "running").length,
			total: sessions.length,
			sessions
		};
	}

	/**
	 * 组出 peak 段。
	 * @param now - 当前时刻。
	 * @returns 峰谷状态对象；规则不可用时为 null。
	 */
	function peakSection(now) {
		if (rules === null) return null;
		const status = peakStatusAt(rules, now);
		const next = nextPeakSwitchFrom(rules, now);
		return {
			kind: status.kind,
			label: status.kind === "peak" ? "峰" : "谷",
			why: status.why,
			timezone: rules.timezone ?? "Asia/Shanghai",
			nextSwitchAt: next === null ? null : next.at,
			nextKind: next === null ? null : next.kind,
			rulesUpdatedAt: rules.rulesUpdatedAt ?? null,
			sourceName: rules.source?.name ?? null,
			sourceUrl: rules.source?.url ?? null
		};
	}

	/**
	 * 写一次状态文件；失败只警告一次。
	 * @returns {void}
	 */
	function flush() {
		try {
			const now = new Date();
			const payload = {
				v: 2,
				pid: process.pid,
				updatedAt: Date.now(),
				work: workSection(),
				peak: peakSection(now),
				approval: { pending: approvals.size }
			};
			mkdirSync(dirname(path), { recursive: true });
			const tmp = path + ".tmp";
			writeFileSync(tmp, JSON.stringify(payload, null, 2) + "\n", "utf8");
			renameSync(tmp, path);
		} catch (error) {
			if (warned) return;
			warned = true;
			ctx.logger?.warn?.(`dsh-indicators: 状态文件写入失败（${path}）：${String(error)}`);
		}
	}

	ctx.effect(() => {
		try {
			rules = JSON.parse(readFileSync(rulesPath(), "utf8"));
		} catch (error) {
			rules = null;
			ctx.logger?.warn?.(`dsh-indicators: 读不到峰谷规则（${rulesPath()}），峰谷那一项会隐藏：${String(error)}`);
		}

		// 先按当前注册表播种，避免插件加载时已有 agent 在运行却显示为空闲。
		for (const agent of ctx.agents.list()) track(agent);

		const stopStatus = ctx.on("agent/status", ({ agent, status }) => {
			track(agent, status);
			flush();
		});
		const stopCreated = ctx.on("agent/created", ({ agent }) => {
			track(agent);
			flush();
		});
		const stopDisposed = ctx.on("agent/disposed", ({ agent }) => {
			agents.delete(agent);
			flush();
		});
		// 授权请求：整个等待期间都视为「存在待授权请求」。
		//
		// 为什么盯 session/event 而不是 approval/request：后者是 waterfall，GUI 那边的
		// answerer 会先 claim 掉这次请求（直接给出 outcome，不再往下传），挂在链尾的
		// 插件根本轮不到 —— 实测就是收不到。而 approval/asked 与 approval/decided 是
		// 落进会话日志的 durable 事件，走 session/event 广播，谁都能看见；按 id 一配对
		// 就是「此刻有几个在等」。
		const stopApproval = ctx.on("session/event", (_session, event) => {
			const id = event?.data?.id;
			if (typeof id !== "string") return;
			if (event.type === "approval/asked") {
				approvals.set(id, { toolName: event.data?.toolName ?? null });
				flush();
			} else if (event.type === "approval/decided") {
				approvals.delete(id);
				flush();
			}
		});
		// 心跳：内容不变也重写，让菜单栏能区分「空闲」和「DSH 已退出」。
		const heartbeat = setInterval(flush, HEARTBEAT_MS);
		// 菜单栏 App 的生死跟着本插件走（也就是跟着 DSH 走）。
		const stopMenuBar = spawnMenuBar(ctx, path);

		let switchTimer = null;

		/** 把定时器对准下一次峰谷切换；心跳负责兜底，这个负责准点。 */
		function armSwitchTimer() {
			if (switchTimer !== null) clearTimeout(switchTimer);
			if (rules === null) {
				switchTimer = null;
				return;
			}
			const next = nextPeakSwitchFrom(rules, new Date());
			if (next === null) {
				switchTimer = null;
				return;
			}
			// 多等 1 秒再刷，确保已经跨过边界。
			const delay = Math.max(1000, next.at - Date.now() + 1000);
			switchTimer = setTimeout(() => {
				flush();
				armSwitchTimer();
			}, delay);
		}

		flush();
		armSwitchTimer();

		return () => {
			// 先收掉菜单栏，让指示器立刻消失，不用等心跳过期。
			stopMenuBar();
			stopStatus();
			stopCreated();
			stopDisposed();
			stopApproval();
			approvals.clear();
			clearInterval(heartbeat);
			if (switchTimer !== null) clearTimeout(switchTimer);
			// 插件卸载（DSH 退出前会走到这里）时把 work 段清空，菜单栏不必等超时。
			agents.clear();
			rules = null;
			flush();
		};
	}, "dsh-indicators: status mirror");
}

export { apply, inject, name, nextPeakSwitchFrom, peakStatusAt, statusFilePath };
