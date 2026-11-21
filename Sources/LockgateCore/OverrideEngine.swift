import Foundation
import JavaScriptCore

public struct OverrideStep: Codable, Equatable {
    public var name: String
    public var kind: OverrideKind
    public var content: String

    public init(name: String, kind: OverrideKind, content: String) {
        self.name = name
        self.kind = kind
        self.content = content
    }
}

public struct OverrideRequest: Codable, Equatable {
    public var profile: String
    public var kind: SubscriptionKind
    public var providerPath: String
    public var steps: [OverrideStep]
    public var runtime: CoreRuntime

    public init(profile: String, kind: SubscriptionKind, providerPath: String, steps: [OverrideStep], runtime: CoreRuntime) {
        self.profile = profile
        self.kind = kind
        self.providerPath = providerPath
        self.steps = steps
        self.runtime = runtime
    }
}

public struct OverrideOutput: Codable, Equatable {
    public var config: String
    public var logs: [String]
}

public struct OverrideError: Error, LocalizedError, Equatable, Codable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 覆写流程：订阅 → 丢弃接管项并填入 Lockgate 默认值 → 依次应用 YAML 覆写和脚本覆写 → 重新强制接管项。
///
/// YAML 覆写的合并规则与 Clash Party（mihomo-party）一致：映射递归合并，其他值直接替换；
/// `+key` 把列表插到原列表前面，`key+` 追加到后面，`key!` 整个替换不合并。
/// 脚本覆写需要定义 `function main(config) { return config }`。
///
/// 脚本在 JavaScriptCore 中运行，没有文件和网络访问能力。本类型不做超时控制，
/// 调用方应在可终止的子进程里运行（见应用里的 OverrideRunner）。
public enum OverrideEngine {
    public static let yamlTemplate = """
    # YAML 覆写：与订阅配置合并，写法与 Clash Party 一致。
    #   key:    映射递归合并，其他类型直接替换
    #   +key:   把列表内容插到原列表最前面
    #   key+:   把列表内容追加到原列表最后
    #   key!:   整个替换，不做合并
    # 端口、控制接口、局域网访问和代理模式由 Lockgate 管理，写在这里不生效。

    # +rules:
    #   - DOMAIN-SUFFIX,example.com,DIRECT

    """

    public static let scriptTemplate = """
    // 脚本覆写：收到当前配置，返回修改后的配置。
    // 可以用 console.log 输出调试信息，结果显示在「覆写」页。
    // 脚本不能访问文件和网络，也不支持异步。
    function main(config) {
      // config.rules = ["DOMAIN-SUFFIX,example.com,DIRECT"].concat(config.rules || []);
      return config;
    }

    """

    private static let glue = """
    var __logs = [];
    var console = { log: function () {
      __logs.push(Array.prototype.map.call(arguments, function (item) {
        if (typeof item === 'string') return item;
        try { return JSON.stringify(item); } catch (error) { return String(item); }
      }).join(' '));
    } };
    console.info = console.warn = console.error = console.debug = console.log;
    function __isMap(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
    function __merge(target, patch) {
      Object.keys(patch).forEach(function (key) {
        var value = patch[key];
        if (key.length > 1 && key.charAt(key.length - 1) === '!') {
          target[key.slice(0, -1)] = value;
        } else if (Array.isArray(value) && key.length > 1 && key.charAt(0) === '+') {
          var head = key.slice(1);
          target[head] = value.concat(Array.isArray(target[head]) ? target[head] : []);
        } else if (Array.isArray(value) && key.length > 1 && key.charAt(key.length - 1) === '+') {
          var tail = key.slice(0, -1);
          target[tail] = (Array.isArray(target[tail]) ? target[tail] : []).concat(value);
        } else if (__isMap(value)) {
          if (!__isMap(target[key])) target[key] = {};
          __merge(target[key], value);
        } else {
          target[key] = value;
        }
      });
      return target;
    }
    function __parseYAML(text) {
      var value = jsyaml.load(text);
      return JSON.stringify(value === undefined ? null : value);
    }
    function __toYAML(text, maskSecret) {
      var value = jsyaml.load(text);
      if (maskSecret && __isMap(value) && value.secret !== undefined) value.secret = '（已隐藏）';
      return jsyaml.dump(value, { lineWidth: -1, noRefs: true });
    }
    function __applyYAML(configJSON, text) {
      var patch = jsyaml.load(text);
      if (patch === undefined || patch === null) return configJSON;
      if (!__isMap(patch)) throw new Error('覆写内容必须是键值映射');
      return JSON.stringify(__merge(JSON.parse(configJSON), patch));
    }
    function __applyScript(configJSON, source) {
      var result;
      try {
        var main = (new Function(source + '\\n;return typeof main === "function" ? main : undefined;'))();
        if (!main) throw new Error('脚本需要定义 main(config) 函数');
        result = main(JSON.parse(configJSON));
      } catch (error) {
        // new Function 会在脚本前加两行函数头，行号要减回去。
        var line = error && typeof error.line === 'number' ? error.line - 2 : 0;
        throw new Error(String(error && error.message !== undefined ? (error.name && error.name !== 'Error' ? error.name + ': ' : '') + error.message : error)
          + (line > 0 ? '（脚本第 ' + line + ' 行）' : ''));
      }
      if (result && typeof result.then === 'function') throw new Error('不支持异步脚本，main(config) 需要直接返回配置');
      if (!__isMap(result)) throw new Error('main(config) 必须返回配置对象');
      return JSON.stringify(result);
    }
    """

    private final class Machine {
        let context: JSContext
        private var failure: String?

        init() throws {
            guard let context = JSContext() else { throw OverrideError("无法创建脚本运行环境。") }
            self.context = context
            context.exceptionHandler = { [weak self] _, exception in
                var message = exception?.toString() ?? "未知错误"
                if message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
                self?.failure = message
            }
            context.evaluateScript(JSYAMLSource.script)
            context.evaluateScript(OverrideEngine.glue)
            if let failure { throw OverrideError("脚本运行环境初始化失败：\(failure)") }
        }

        func call(_ function: String, _ arguments: [String], label: String) throws -> String {
            failure = nil
            let result = context.objectForKeyedSubscript(function)?.call(withArguments: arguments)
            if let failure { throw OverrideError("\(label)：\(failure)") }
            guard let result, result.isString, let text = result.toString() else {
                throw OverrideError("\(label)：没有得到有效结果。")
            }
            return text
        }

        var logs: [String] {
            (context.objectForKeyedSubscript("__logs")?.toArray() as? [String]) ?? []
        }
    }

    private static func object(_ json: String, label: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw OverrideError("\(label)：结果不是键值映射。")
        }
        return object
    }

    private static func json(_ object: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            throw OverrideError("配置中含有无法序列化的内容。")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 把配置（YAML 或 JSON）整理成便于阅读的 YAML，用于在界面上查看。控制接口密钥会被隐藏。
    public static func readableYAML(_ text: String) throws -> String {
        let machine = try Machine()
        guard let function = machine.context.objectForKeyedSubscript("__toYAML"),
              let result = function.call(withArguments: [text, true]), result.isString,
              let yaml = result.toString() else {
            throw OverrideError("配置内容无法解析。")
        }
        return yaml
    }

    public static func run(_ request: OverrideRequest) throws -> OverrideOutput {
        let machine = try Machine()
        let base: [String: Any]
        if request.kind == .provider {
            base = ProfileComposer.providerObject(path: request.providerPath)
        } else {
            base = try object(machine.call("__parseYAML", [request.profile], label: "订阅配置解析失败"), label: "订阅配置")
        }
        var config = try json(ProfileComposer.prepared(base, runtime: request.runtime))
        for step in request.steps {
            let label = "覆写「\(step.name)」出错"
            config = try machine.call(step.kind == .yaml ? "__applyYAML" : "__applyScript", [config, step.content], label: label)
        }
        let final = ProfileComposer.finalized(try object(config, label: "覆写结果"), runtime: request.runtime)
        return OverrideOutput(config: final, logs: machine.logs)
    }
}
