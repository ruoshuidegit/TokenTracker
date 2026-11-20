const fs = require("node:fs");
const path = require("node:path");
const { builtinModules } = require("node:module");

// 只打包本地用量解析与离线计价，不启动 CLI、HTTP 服务或云端同步。
function bundleRuntime(repoRoot, resources, { includeCollectors = true } = {}) {
  const builtins = new Set(builtinModules.flatMap((name) => [name, `node:${name}`]));
  const visited = new Set();
  const rolloutModule = path.join(repoRoot, "src/lib/rollout.js");
  const copyModule = (file) => {
    if (visited.has(file)) return;
    visited.add(file);
    const relative = path.relative(repoRoot, file);
    if (relative.startsWith("..")) throw new Error("运行时依赖超出项目目录");
    const target = path.join(resources, relative);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(file, target);
    if (!file.endsWith(".js") && !file.endsWith(".cjs")) return;
    const code = fs.readFileSync(file, "utf8");
    for (const match of code.matchAll(/\brequire\(\s*["']([^"']+)["']\s*\)/g)) {
      const dependency = match[1];
      if (builtins.has(dependency)) continue;
      if (!dependency.startsWith(".")) {
        // rollout 的其他工具解析器懒加载此 Node 20 压缩兼容模块；
        // Lite 仅调用 Antigravity／OMP，二者都不读取 Zstandard 文件。
        if (includeCollectors && file === rolloutModule && dependency === "@mongodb-js/zstd") continue;
        throw new Error(`Lite 运行时出现外部依赖：${dependency}`);
      }
      copyModule(require.resolve(path.resolve(path.dirname(file), dependency)));
    }
  };
  copyModule(path.join(repoRoot, "src/lib/pricing/index.js"));
  if (includeCollectors) copyModule(rolloutModule);
  // seed-snapshot 通过 fs 读取，不在 require 依赖图中。
  const pricing = path.join(repoRoot, "src/lib/pricing");
  for (const name of fs.readdirSync(pricing)) {
    if (name.endsWith(".json")) {
      const target = path.join(resources, "src/lib/pricing", name);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.copyFileSync(path.join(pricing, name), target);
    }
  }
  for (const name of ["LICENSE", "THIRD_PARTY_NOTICES.md"]) {
    fs.copyFileSync(path.join(repoRoot, name), path.join(resources, name));
  }
  return visited.size;
}

function bundlePricing(repoRoot, resources) {
  return bundleRuntime(repoRoot, resources, { includeCollectors: false });
}

if (require.main === module) {
  const resources = process.argv[2];
  if (!resources) throw new Error("缺少应用资源输出目录");
  console.log(`已打包 ${bundleRuntime(path.resolve(__dirname, ".."), resources)} 个本地采集与离线计价模块`);
}

module.exports = { bundlePricing, bundleRuntime };
