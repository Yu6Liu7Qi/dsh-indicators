#!/usr/bin/env node
/**
 * 编译菜单栏 App：`menubar/main.swift` → `menubar/MenuBarIndicators`（universal）。
 *
 * 有两件事必须做对，否则别人装上了也跑不起来：
 *
 *   1. **钉部署目标**。不写 `-target` 的话，二进制里记的最低系统版本会跟着编译机
 *      的 SDK 走 —— 在一台 macOS 28 上编出来的东西，macOS 26 的用户双击只会得到
 *      「需要更高版本的 macOS」。该问题在实际编译中出现过。
 *   2. **出 universal**（arm64 + x86_64）。只出 arm64 的话 Intel Mac 直接不认。
 *
 * 没装 Command Line Tools 时（找不到 swiftc）**不算失败**：仓库里带着一份预编译
 * 好的 universal 二进制，直接用那份就行。所以这个脚本既能挂 `prepare`（装插件时
 * 自动跑），也能手动跑。
 *
 * 用法：
 *   node scripts/build-menubar.mjs          编译（没有 swiftc 就保留现有二进制）
 *   node scripts/build-menubar.mjs --check  只看现有二进制的架构与最低系统版本
 */
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, renameSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** 本文件所在目录（`scripts/`）。 */
const here = dirname(fileURLToPath(import.meta.url));
/** 插件根目录。 */
const root = join(here, "..");
/** 源码。 */
const source = join(root, "menubar", "main.swift");
/** 产物。 */
const output = join(root, "menubar", "MenuBarIndicators");
/** 最低支持的 macOS 版本，两种架构都钉它。 */
const DEPLOYMENT_TARGET = "13.0";
/** 要合的架构：Apple Silicon + Intel。 */
const ARCHES = ["arm64", "x86_64"];

/**
 * 找 swiftc。
 * @returns 可执行的 swiftc 路径；没装 Command Line Tools 时为 null。
 */
function findSwiftc() {
	const viaXcrun = spawnSync("xcrun", ["-f", "swiftc"], { encoding: "utf8" });
	if (viaXcrun.status === 0 && viaXcrun.stdout.trim()) return viaXcrun.stdout.trim();
	const viaPath = spawnSync("swiftc", ["--version"], { encoding: "utf8" });
	return viaPath.status === 0 ? "swiftc" : null;
}

/**
 * 找 macOS SDK。
 *
 * **指定 `-target` 时必须同时给 `-sdk`**：只给 `-target` 的话，swiftc 会因为找不到
 * 对应版本的标准库而报 `unable to load standard library for target ...`，即使机器
 * 上装着两个 SDK 也一样。（实测：`-target arm64-apple-macos13.0` 单用必失败，
 * 补上 `-sdk MacOSX26.5.sdk` 立刻通过。）用最新的 SDK 编最低的部署目标是标准做法。
 * @returns SDK 路径；找不到时为 null。
 */
function findSdk() {
	const viaXcrun = spawnSync("xcrun", ["--show-sdk-path", "--sdk", "macosx"], { encoding: "utf8" });
	const path = (viaXcrun.stdout ?? "").trim();
	if (viaXcrun.status === 0 && path && existsSync(path)) return path;
	const candidates = [
		"/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
		"/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
	];
	return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

/**
 * 读现有二进制的架构与最低系统版本。
 * @returns {{ archs: string, minos: string } | null} 读不到（文件不存在）时为 null。
 */
function inspect() {
	if (!existsSync(output)) return null;
	const archs = spawnSync("lipo", ["-archs", output], { encoding: "utf8" });
	const load = spawnSync("otool", ["-l", output], { encoding: "utf8" });
	const minos = /minos\s+([0-9.]+)/.exec(load.stdout ?? "")?.[1] ?? "未知";
	return {
		archs: (archs.stdout ?? "").trim() || "未知",
		minos,
	};
}

/** 打印现有二进制的体检结果。 */
function check() {
	const info = inspect();
	if (info === null) {
		console.log(`✘ 还没有 ${output}，可运行 node scripts/build-menubar.mjs 生成`);
		return;
	}
	const { size } = statSync(output);
	const universal = ARCHES.every((arch) => info.archs.includes(arch));
	console.log(`二进制：${output}`);
	console.log(`  架构        ${info.archs}${universal ? "" : "   ← 不是 universal，Intel Mac 跑不了"}`);
	console.log(`  最低 macOS  ${info.minos}${info.minos === DEPLOYMENT_TARGET ? "" : `   ← 目标是 ${DEPLOYMENT_TARGET}`}`);
	console.log(`  大小        ${Math.round(size / 1024)} KB`);
}

const checkOnly = process.argv.includes("--check");
check();

if (checkOnly) process.exit(0);

const swiftc = findSwiftc();
if (swiftc === null) {
	console.log("· 没找到 swiftc（未装 Xcode Command Line Tools）—— 保留仓库里预编译的二进制。");
	console.log("  想自己编译：xcode-select --install");
	process.exit(0);
}
const sdk = findSdk();
if (sdk === null) {
	console.log("· 没找到 macOS SDK —— 保留仓库里预编译的二进制。");
	process.exit(0);
}
console.log(`· 工具链：${swiftc}`);
console.log(`· SDK：${sdk}`);

const workdir = mkdtempSync(join(tmpdir(), "dsh-indicators-menubar-"));
try {
	const slices = ARCHES.map((arch) => {
		const out = join(workdir, `MenuBarIndicators-${arch}`);
		console.log(`· 编译 ${arch}（最低 macOS ${DEPLOYMENT_TARGET}）…`);
		execFileSync(
			swiftc,
			[
				"-O",
				"-swift-version",
				"5",
				"-sdk",
				sdk,
				"-target",
				`${arch}-apple-macos${DEPLOYMENT_TARGET}`,
				"-o",
				out,
				source,
			],
			{ stdio: "inherit" },
		);
		return out;
	});
	console.log("· 合并成 universal…");
	// 先落到同目录的临时名再 rename：菜单栏 App 可能正跑着，覆盖运行中的可执行
	// 文件会拿到 ETXTBSY；rename 是原子的，正在运行的进程不受影响，下次启动即新版。
	const staged = join(root, "menubar", ".MenuBarIndicators.new");
	execFileSync("lipo", ["-create", ...slices, "-output", staged], { stdio: "inherit" });
	execFileSync("chmod", ["755", staged]);
	renameSync(staged, output);
} finally {
	rmSync(workdir, { recursive: true, force: true });
}

console.log("✔ 编译完成");
check();
