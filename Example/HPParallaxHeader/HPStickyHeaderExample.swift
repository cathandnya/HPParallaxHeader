//
//  HPStickyHeaderExample.swift
//  HPParallaxHeader
//
//  Repro screen for the production EXC_BAD_ACCESS crash in
//  HPScrollView.observeValue (KVO re-entrancy → SwiftUI generic metadata
//  resolution) seen in the Rocky app's UserProfileViewController.
//
//  ── View construction mirrors the crashing production screen ──────────────
//  Production: UserProfileViewController : ParallaxContentViewController :
//              HPScrollViewController.
//    HPScrollViewController.scrollView (HPScrollView)
//      ├─ parallaxHeader.view  ← a header UIViewController's SwiftUI hosting view
//      └─ childViewController.view  ← a SwiftUI hosting view (the CONTENT)
//                                     pinned top/bottom, height == scrollView
//                                     height − headerMinimumHeight.
//  The SwiftUI content scrolls via an internal UITableView (SwiftUI `List`).
//  That's the `UITableView _updateVisibleCellsNow` / `_restoreOrAdjust
//  ContentOffset` chain in the production stack — NOT a hand-built table.
//
//  So this repro subclasses HPScrollViewController exactly like production and
//  puts a SwiftUI `List` of self-sizing rows in childViewController. The header
//  is also a SwiftUI hosting view. A CADisplayLink drives a fast scroll on the
//  HPScrollView so the parallax-header + child coupling churns offsets quickly,
//  re-entering HPScrollView.observeValue while SwiftUI resolves cell metadata.
//
//  Run it: select the "Sticky" tab, tap "Start fast scroll".
//

import UIKit
import SwiftUI
import HPParallaxHeader

class HPStickyHeaderExample: HPScrollViewController, HPScrollViewDelegate {

    private let headerFullHeight: CGFloat = 280
    private let headerStickyHeight: CGFloat = 88

    // Fast-scroll driver UI
    private let autoScrollButton = UIButton(type: .system)
    private let offsetLabel = UILabel()
    private var displayLink: CADisplayLink?
    private var isAutoScrolling = false
    private var tick: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        title = "Sticky"

        // Match production: scrollView is built by HPScrollViewController.
        scrollView.delegate = self
        if #available(iOS 11.0, *) {
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        // Order matters: childViewController must exist before we set
        // headerMinimumHeight, because HPScrollViewController.headerMinimumHeight
        // also updates childHeightConstraint (which is nil until the child is
        // installed). With production parity the content sits below the sticky
        // strip and the strip stays pinned.
        setUpContent()
        setUpParallaxHeader()
        setUpAutoScrollControls()
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Parallax header (SwiftUI hosting, like production)

    private func setUpParallaxHeader() {
        let header = UIHostingController(rootView: HeaderView(stickyHeight: headerStickyHeight))
        header.view.backgroundColor = .clear
        // headerViewController is consumed by HPScrollViewController: it sets
        // scrollView.parallaxHeader.view = header.view and adds it as a child.
        headerViewController = header

        headerHeight = headerFullHeight
        headerMinimumHeight = headerStickyHeight
        scrollView.parallaxHeader.mode = .topFill
    }

    // MARK: - Content (SwiftUI List, like production's UserProfileContentView)

    private func setUpContent() {
        let content = UIHostingController(rootView: ContentView(model: rowModel))
        content.view.backgroundColor = .clear
        // childViewController is consumed by HPScrollViewController: it pins the
        // view top/bottom and sets height == scrollView height − minimumHeight.
        childViewController = content
    }

    /// Shared model so we can mutate row heights from the display link to force
    /// the SwiftUI List's internal UITableView to re-measure self-sizing cells.
    private let rowModel = RowModel()

    // MARK: - Fast-scroll repro controls

    private func setUpAutoScrollControls() {
        autoScrollButton.translatesAutoresizingMaskIntoConstraints = false
        autoScrollButton.setTitle("Start fast scroll", for: .normal)
        autoScrollButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        autoScrollButton.setTitleColor(.white, for: .normal)
        autoScrollButton.backgroundColor = #colorLiteral(red: 0.1764705926, green: 0.4980392158, blue: 0.7568627596, alpha: 1)
        autoScrollButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        autoScrollButton.layer.cornerRadius = 8
        autoScrollButton.addTarget(self, action: #selector(toggleAutoScroll), for: .touchUpInside)
        view.addSubview(autoScrollButton)

        offsetLabel.translatesAutoresizingMaskIntoConstraints = false
        offsetLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        offsetLabel.textColor = .white
        offsetLabel.textAlignment = .center
        offsetLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        offsetLabel.text = "offset.y: 0"
        view.addSubview(offsetLabel)

        NSLayoutConstraint.activate([
            autoScrollButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            autoScrollButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),

            offsetLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            offsetLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            offsetLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            offsetLabel.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @objc private func toggleAutoScroll() {
        isAutoScrolling ? stopAutoScroll() : startAutoScroll()
    }

    private func startAutoScroll() {
        isAutoScrolling = true
        autoScrollButton.setTitle("Stop fast scroll", for: .normal)

        let link = CADisplayLink(target: self, selector: #selector(stepAutoScroll))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAutoScroll() {
        isAutoScrolling = false
        autoScrollButton.setTitle("Start fast scroll", for: .normal)
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Drive the HPScrollView through a fast top↔bottom sweep. Periodically
    /// (not every frame) change the ROW COUNT — this is what the production
    /// crash needs: `refresh()` swaps the data, the row count changes mid-scroll,
    /// and UITableView runs `_restoreOrAdjustContentOffsetWithRowCount` to keep
    /// position. That offset correction fires the KVO that re-enters
    /// HPScrollView.observeValue while SwiftUI resolves cell metadata.
    ///
    /// Row HEIGHTS stay stable (no per-frame jitter) — that was visual noise and
    /// not part of the real crash.
    @objc private func stepAutoScroll(_ link: CADisplayLink) {
        tick &+= 1

        // Every ~12 frames, change the row count mid-scroll (the refresh()
        // analogue that triggers _restoreOrAdjustContentOffset).
        if tick % 12 == 0 {
            rowModel.reshuffle()
        }

        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height
                       - scrollView.bounds.height
                       + scrollView.adjustedContentInset.bottom)
        guard maxY > minY else { return }

        let period = 120.0
        let phase = Double(tick).truncatingRemainder(dividingBy: period) / period
        let tri = phase < 0.5 ? (phase * 2) : (2 - phase * 2) // 0→1→0
        let targetY = minY + CGFloat(tri) * (maxY - minY)

        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)

        offsetLabel.text = String(format: "offset.y: %.0f / max %.0f  rows: %d  tick: %d",
                                  scrollView.contentOffset.y, maxY, rowModel.rows.count, tick)
    }

    // MARK: - HPScrollViewDelegate

    func scrollViewShouldScroll(_ scrollView: HPScrollView, with subView: UIScrollView) -> Bool {
        return true
    }
}

// MARK: - SwiftUI header (mirrors a hosting-view parallax header)

private struct HeaderView: View {
    let stickyHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Profile header")
                    .font(.title.bold())
                    .foregroundColor(.white)
                Text("Hides as you scroll up")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 60)

            // The strip that stays pinned (matches headerMinimumHeight).
            Text("Sticky bar")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: stickyHeight)
                .background(Color.pink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.13, green: 0.22, blue: 0.07))
    }
}

// MARK: - SwiftUI content (a List of self-sizing rows = internal UITableView)

/// Observable model whose `rows` array changes COUNT on each reshuffle — the
/// production `refresh()` analogue. Row heights themselves are stable (each
/// row's `height` is a fixed function of its id), so there's no visual jitter;
/// only the number of rows changes, which is what makes UITableView run
/// `_restoreOrAdjustContentOffsetWithRowCount` mid-scroll.
private final class RowModel: ObservableObject {
    @Published private(set) var rows: [Int] = Array(0..<60)
    private var generation = 0

    func reshuffle() {
        generation &+= 1
        // Oscillate the count between ~45 and ~75 rows so the table keeps
        // adjusting its content size / offset as data "refreshes".
        let count = 60 + (generation % 2 == 0 ? 15 : -15)
        rows = Array(0..<count)
    }
}

private struct ContentView: View {
    @ObservedObject var model: RowModel

    var body: some View {
        List(model.rows, id: \.self) { row in
            RowCell(row: row)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .background(Color.white)
    }
}

private struct RowCell: View {
    let row: Int

    var body: some View {
        // Stable self-sizing height: a fixed function of the row id (no jitter).
        let extra = CGFloat(row % 7) * 12

        VStack(alignment: .leading, spacing: 6) {
            Text("Row \(row)")
                .font(.headline)
            Text("Self-sizing SwiftUI row inside a parallax HPScrollView.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Color.blue.opacity(0.15)
                .frame(height: 20 + extra)
                .cornerRadius(6)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
