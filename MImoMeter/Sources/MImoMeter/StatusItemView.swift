import AppKit

final class StatusItemView: NSView {
    private let percentage = NSTextField(labelWithString: "--%")
    private let underline = NSView()
    private var percentCenterY: NSLayoutConstraint?
    private var percentTopY: NSLayoutConstraint?
    static let meterOrange = NSColor(srgbRed: 1.0, green: 120.0 / 255.0, blue: 20.0 / 255.0, alpha: 1)
    static let taskYellow = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.0, alpha: 1)
    static let taskGreen = NSColor(srgbRed: 0.2, green: 0.75, blue: 0.25, alpha: 1)
    static let taskRed = NSColor(srgbRed: 0.95, green: 0.2, blue: 0.18, alpha: 1)
    static let taskGray = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)

    private static let horizontalPadding: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let fieldWidth = percentage.intrinsicContentSize.width
        return NSSize(width: ceil(max(10, fieldWidth) + Self.horizontalPadding * 2), height: 24)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        percentage.translatesAutoresizingMaskIntoConstraints = false
        percentage.font = .menuBarFont(ofSize: 0)
        percentage.alignment = .center
        percentage.lineBreakMode = .byClipping
        percentage.setContentCompressionResistancePriority(.required, for: .horizontal)
        percentage.setContentHuggingPriority(.required, for: .horizontal)

        underline.translatesAutoresizingMaskIntoConstraints = false
        underline.wantsLayer = true
        underline.layer?.backgroundColor = Self.meterOrange.cgColor
        underline.layer?.cornerRadius = 1
        underline.isHidden = true

        addSubview(percentage)
        addSubview(underline)

        // Two exclusive layouts for the number: centered (default) vs lifted (underline on).
        let centerY = percentage.centerYAnchor.constraint(equalTo: centerYAnchor)
        let topY = percentage.topAnchor.constraint(equalTo: topAnchor, constant: 3)
        topY.isActive = false
        percentCenterY = centerY
        percentTopY = topY

        // Keep the label sized to its text (not stretched), so 100% → 99%
        // keeps the underline centered under the glyphs.
        NSLayoutConstraint.activate([
            percentage.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.horizontalPadding),
            percentage.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalPadding),
            percentage.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
            underline.topAnchor.constraint(equalTo: percentage.bottomAnchor, constant: 1),
            underline.heightAnchor.constraint(equalToConstant: 3),
            underline.centerXAnchor.constraint(equalTo: percentage.centerXAnchor),
            underline.widthAnchor.constraint(equalTo: percentage.widthAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        percentage.stringValue = "--%"
    }

    func update(
        percentage text: String,
        color: NSColor,
        accessibilityLabel: String,
        showsUnderline: Bool,
        underlineColor: NSColor? = nil
    ) {
        percentage.stringValue = text
        percentage.textColor = color
        if let underlineColor {
            underline.layer?.backgroundColor = underlineColor.cgColor
        } else {
            underline.layer?.backgroundColor = Self.meterOrange.cgColor
        }
        applyUnderlineVisibility(showsUnderline)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyUnderlineVisibility(_ shows: Bool) {
        underline.isHidden = !shows
        percentCenterY?.isActive = !shows
        percentTopY?.isActive = shows
        needsLayout = true
    }
}
