import ApplicationServices
import CoreFoundation

@inline(__always)
func warpAXElement(_ value: AnyObject?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

@inline(__always)
func warpAXValue(_ value: AnyObject?) -> AXValue? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    return (value as! AXValue)
}
