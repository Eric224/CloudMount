import Logging
public func clientLogger() -> Logger { var value = Logger(label: "CloudMount.SFTP"); value.logLevel = .critical; return value }
