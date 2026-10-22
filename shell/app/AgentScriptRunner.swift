import JavaScriptCore

@MainActor
final class AgentScriptRunner {
    private let commands: AgentCommands
    private let session: String
    private let timeout: Double
    private var output: [String] = []

    init(commands: AgentCommands, session: String, timeout: Double) {
        self.commands = commands
        self.session = session
        self.timeout = timeout
    }

    private static let prelude = #"""
    const __flags = (o = {}) => Object.entries(o)
      .flatMap(([k, v]) => v === false || v == null ? [] : v === true ? ['--' + k] : ['--' + k, String(v)]);
    const __tab = o => o && o.tab ? ['--tab', String(o.tab)] : [];
    const mbga = (...argv) => __call(argv.map(String));
    const tabs = (o) => mbga('tabs', ...__flags(o));
    const open = async (url, o) => { const t = await mbga('open', url, ...__flags(o)); return t.split(' ')[0]; };
    const use = tab => mbga('use', tab);
    const goto = (url, o) => mbga('goto', url, ...__flags(o));
    const back = o => mbga('back', ...__flags(o));
    const reload = o => mbga('reload', ...__flags(o));
    const snapshot = o => mbga('snapshot', ...__flags(o));
    const read = o => mbga('read', ...__flags(o));
    const find = (text, o) => mbga('find', text, ...__flags(o));
    const click = (target, o) => mbga('click', target, ...__flags(o));
    const fill = (target, text, o) => mbga('fill', target, text, ...__flags(o));
    const press = (key, o) => mbga('press', key, ...__flags(o));
    const select = (target, value, o) => mbga('select', target, value, ...__flags(o));
    const scroll = (where, o) => mbga('scroll', where || 'down', ...__flags(o));
    const wait = (what, o) => typeof what === 'object'
      ? mbga('wait', what.gone ? 'gone' : 'text', what.gone || what.text, ...__flags(o))
      : mbga('wait', String(what), ...__flags(o));
    const screenshot = o => mbga('screenshot', ...__flags(o));
    const consoleMessages = o => mbga('console', ...__flags(o));
    const sleep = ms => mbga('wait', String(ms));
    const evaluate = async (fn, ...args) => {
      const o = args.length && args[args.length - 1] && args[args.length - 1].__mbga ? args.pop() : null;
      const code = typeof fn === 'function' ? `(${fn})(...${JSON.stringify(args)})` : String(fn);
      return JSON.parse(await mbga('eval', code, '--timeout', String(__timeout), ...__tab(o)));
    };
    const tab = t => ({ __mbga: true, tab: t });
    const log = (...a) => __log(a.map(v => typeof v === 'string' ? v : JSON.stringify(v, null, 1)).join(' '));
    const console = { log, info: log, warn: log, error: log };
    """#

    func run(_ argument: String) async throws -> String {
        guard let context = JSContext() else { throw AgentError("Couldn't start a script.") }
        let call: @convention(block) (JSValue) -> JSValue = { [weak self] argv in
            let words = argv.toArray()?.compactMap { $0 as? String } ?? []
            return JSValue(newPromiseIn: context) { resolve, reject in
                Task { @MainActor in
                    guard let self else { return }
                    if words.first == "run" {
                        reject?.call(withArguments: ["Scripts can't run scripts."])
                        return
                    }
                    switch await self.commands.run(words, session: self.session) {
                    case .success(let text): resolve?.call(withArguments: [text])
                    case .failure(let error): reject?.call(withArguments: [JSValue(newErrorFromMessage: error, in: context) as Any])
                    }
                }
            }
        }
        let collect: @convention(block) (String) -> Void = { [weak self] line in self?.output.append(line) }
        context.setObject(call, forKeyedSubscript: "__call" as NSString)
        context.setObject(collect, forKeyedSubscript: "__log" as NSString)
        context.evaluateScript("const __timeout = \(Int(timeout));\n" + Self.prelude)
        let wrapped = "(async () => {\n\(argument)\n})()"
        guard let promise = context.evaluateScript(wrapped) else { throw AgentError("The script didn't start.") }
        if let exception = context.exception {
            throw AgentError("Script error: \(exception.toString() ?? "")")
        }
        let value: JSValue = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let fulfil: @convention(block) (JSValue) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            let fail: @convention(block) (JSValue) -> Void = { error in
                guard !finished else { return }
                finished = true
                let message = error.objectForKeyedSubscript("message")?.toString()
                continuation.resume(throwing: AgentError("Script error: \(message.flatMap { $0 == "undefined" ? nil : $0 } ?? error.toString() ?? "")"))
            }
            promise.invokeMethod("then", withArguments: [
                JSValue(object: fulfil, in: context) as Any, JSValue(object: fail, in: context) as Any,
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !finished else { return }
                finished = true
                continuation.resume(throwing: AgentError("The script ran out of time (\(Int(self.timeout)) s; --timeout to allow more)."))
            }
        }
        var out = output
        if !value.isUndefined, !value.isNull {
            let json = context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value, NSNull(), 1])
            out.append(value.isString ? value.toString() : json?.toString() ?? "")
        }
        return out.isEmpty ? "done" : out.joined(separator: "\n")
    }
}
