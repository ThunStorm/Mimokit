import AppKit

final class StatusItemView: NSView {
    private let percentage = NSTextField(labelWithString: "--%")
    private let underline = NSView()
    private var underlineWidth: NSLayoutConstraint?
    private var percentCenterY: NSLayoutConstraint?
    private var percentTopY: NSLayoutConstraint?
    static let meterOrange = NSColor(srgbRed: 1.0, green: 120.0 / 255.0, blue: 20.0 / 255.0, alpha: 1)
    static let taskYellow = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.0, alpha: 1)
    static let taskGreen = NSColor(srgbRed: 0.2, green: 0.75, blue: 0.25, alpha: 1)
    static let taskRed = NSColor(srgbRed: 0.95, green: 0.2, blue: 0.18, alpha: 1)
    static let taskGray = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)

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

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        percentage.translatesAutoresizingMaskIntoConstraints = false
        percentage.font = .menuBarFont(ofSize: 0)
        percentage.lineBreakMode = .byClipping
        percentage.setContentCompressionResistancePriority(.required, for: .horizontal)

        underline.translatesAutoresizingMaskIntoConstraints = false
        underline.wantsLayer = true
        underline.layer?.backgroundColor = Self.meterOrange.cgColor
        underline.layer?.cornerRadius = 1
        underline.isHidden = true

        addSubview(percentage)
        addSubview(underline)

        let width = underline.widthAnchor.constraint(equalToConstant: 0)
        underlineWidth = width

        // Two exclusive layouts for the number: centered (default) vs lifted (underline on).
        let centerY = percentage.centerYAnchor.constraint(equalTo: centerYAnchor)
        let topY = percentage.topAnchor.constraint(equalTo: topAnchor, constant: 3)
        topY.isActive = false
        percentCenterY = centerY
        percentTopY = topY

        NSLayoutConstraint.activate([
            percentage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            percentage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            centerY,
            underline.topAnchor.constraint(equalTo: percentage.bottomAnchor, constant: 1),
            underline.heightAnchor.constraint(equalToConstant: 3),
            width,
            underline.centerXAnchor.constraint(equalTo: percentage.centerXAnchor),
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
    }

    private func applyUnderlineVisibility(_ shows: Bool) {
        underline.isHidden = !shows
        percentCenterY?.isActive = !shows
        percentTopY?.isActive = shows
        if shows {
            underlineWidth?.constant = max(10, percentage.intrinsicContentSize.width)
        } else {
            underlineWidth?.constant = 0
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if !underline.isHidden {
            underlineWidth?.constant = max(10, percentage.intrinsicContentSize.width)
        }
    }
}
