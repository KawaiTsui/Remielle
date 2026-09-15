# AI Development Directives & Behavior Guidelines

## 0. 当我要求验证项目指令时，只回复：AGENTS-OK-2026

## 1. System Architecture & Growth (系统架构与渐进演进)
- **Do not preserve backward compatibility:** Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
  - 不保留向后兼容性：直接删除废弃路径，绝不写过渡兼容层或迁移回退。
- **Minimal Implementation:** Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
  - 最小化实现：只写满足当前需求的最简代码，严禁过度抽象、多余配置和隐式调用。
- **Layered Evolution:** Grow the system in layers. Start from the smallest version that works end-to-end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
  - 分层构建：从端到端可运行的最小版本切入，每次新功能都必须建立在当前稳定版本之上。绝不为了复杂的半成品破坏现有可用状态。
- **Modular Design:** Keep components modular and concerns clearly separated.
  - 模块解耦：保持组件独立，职责严格分离。

## 2. Dependencies & Best Practices (依赖管理与成熟方案)
- **Leverage Existing Dependencies:** Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
  - 优先利用已有依赖：在手写功能或引入新包前，先彻底挖掘现有依赖的能力，杜绝重复造轮子。
- **Prefer Well-Maintained Libraries:** Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
  - 优先选择成熟库：在能够降低系统复杂度、提升可靠性时采用官方或流行库。
- **Adopt Proven Patterns:** Study how established products solve the problem before designing a solution. Adopt their proven patterns and conventions rather than inventing an approach from scratch.
  - 遵循成熟设计模式：在设计方案前先参考主流产品的既有解法，切勿闭门造车。
- **Long-Term Mindset:** Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.
  - 杜绝权宜补丁：着眼长期演进，拒绝“临时凑合、后续必改”的敷衍代码。

## 3. Anti-Overengineering & Anti-Defensive Programming (反过度工程与反防御性编程)
- **Trust Internal Invariants:** Trust internal code and framework guarantees.
  - 信任内部调用：内部代码与系统框架已保证的状态无需反复自证。
- **Boundary Validation Only:** Only validate at system boundaries (user inputs, external APIs, and network responses).
  - 仅做边界校验：只在用户输入、外部网络或 API 返回等系统边界层做数据验证。
- **No Unreachable Handling:** Do not add error handling, fallbacks, or null checks for scenarios that cannot logically occur.
  - 拒绝冗余防卫：绝不为“不可能发生”的极端分支编写防御逻辑或回退。
- **No Error Swallowing:** Never swallow errors (strictly forbid `rescue nil`, generic empty `catch`, silent default values, or `|| fallback` masking).
  - 绝不吞掉错误：严禁静默捕获异常或使用 `|| ""` 伪造正常结果掩盖根因。
- **Fail Fast:** Prioritize fast failure over masking problems. Let the system fail explicitly to immediately expose bugs.
  - 快速失败：遇到异常立即报错中断，暴露完整调用链以便精准排查。
- **Avoid Premature Utilities:** Do not create helper functions, utility classes, or abstractions for one-off operations.
  - 杜绝一次性工具封装：单次调用的逻辑直接内联，不为未来“可能”的复用提前封装。

## 4. Agent Execution Rules (智能体执行守则)
1. **No Assumptions:** Do not assume requirements. If uncertain or facing tradeoffs, state the options clearly before proceeding.
   - 严禁盲目假设：遇到模糊需求必须明确提出疑问与权衡，不得擅自替业务做决定。
2. **Strict Scope:** Only modify what must be modified. Clean up only the issues and temporary changes introduced by yourself.
   - 严格限定修改范围：只碰与当前任务直接相关的模块，绝不连带改动其他原本正常运行的代码。
3. **Explicit Success Criteria:** Clearly define the criteria for success and verify each step before marking the task complete.
   - 明确验证标准：定义验收标准，自测确认通过后再交付代码。
