//
//  ExampleTabBarController.swift
//  HPParallaxHeader
//
//  Appends the code-built repro screens to the storyboard's tab bar.
//

import UIKit

class ExampleTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let sticky = HPStickyHeaderExample()
        sticky.tabBarItem = UITabBarItem(title: "Sticky",
                                         image: UIImage(named: "List"),
                                         selectedImage: nil)

        viewControllers = (viewControllers ?? []) + [sticky]
    }
}
