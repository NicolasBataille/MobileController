/// A capture of `idb ui describe-all --json`, anonymised.
///
/// Taken from a real iOS 26.5 simulator and then rewritten against this repository's own
/// public `DemoApp` rather than any private app: the *shape* is what matters — a flat array,
/// `AXLabel`/`AXUniqueId`/`type`/`enabled`, a `frame` whose members are floating point and
/// routinely land a third of a point off an integer, and keys in no particular order.
///
/// Deliberately included, because each one is a rule `frames` has to apply:
/// - an element with an `AXUniqueId` and one without (`#id` versus `@index`);
/// - a label longer than the 40-character cap, and a CJK label that is short in characters
///   but long in bytes;
/// - a `TextField` whose `AXLabel` is null and whose `AXValue` carries the text;
/// - a `CheckBox`, which is how idb reports a switch;
/// - a disabled `Button`;
/// - a zero-size element and a fully offscreen one, both of which must be dropped;
/// - elements in all three bands, out of reading order.
enum ElementFixture {

    /// The label of the application element, which becomes the header.
    static let appLabel = "DemoApp"

    static let describeAll = """
        [
          {"role_description":"application","enabled":true,"pid":100,"traits":["None"],
           "title":null,"content_required":false,"frame":{"x":0,"height":874,"y":0,"width":402},
           "custom_actions":[],"AXUniqueId":null,"AXValue":null,"AXLabel":"DemoApp",
           "type":"Application","AXFrame":"{{0, 0}, {402, 874}}","help":null,"subrole":null,
           "role":"AXApplication"},
          {"AXUniqueId":"nav.back","AXLabel":"Back","AXValue":null,"type":"Button",
           "role":"AXButton","enabled":true,"traits":["Button"],
           "frame":{"x":16,"y":62,"width":44,"height":44}},
          {"AXUniqueId":null,"AXLabel":"Bienvenue dans la démonstration d'accessibilité mobile",
           "AXValue":null,"type":"Heading","role":"AXHeading","enabled":true,
           "frame":{"x":15.999999999999986,"y":119.66666666666667,
                    "width":147.33333333333331,"height":40.666666666666671}},
          {"AXUniqueId":null,"AXLabel":"こんばんは","AXValue":null,"type":"StaticText",
           "role":"AXStaticText","enabled":true,
           "frame":{"x":24,"y":200,"width":64,"height":13}},
          {"AXUniqueId":"form.email","AXLabel":null,"AXValue":"user@example.com",
           "type":"TextField","role":"AXTextField","enabled":true,
           "frame":{"x":36,"y":260,"width":330,"height":44}},
          {"AXUniqueId":"form.motion","AXLabel":"Réduire les animations","AXValue":"0",
           "type":"CheckBox","role":"AXCheckBox","enabled":true,
           "frame":{"x":36,"y":320,"width":330,"height":28}},
          {"AXUniqueId":null,"AXLabel":"Logo","AXValue":null,"type":"Image","role":"AXImage",
           "enabled":true,"frame":{"x":170,"y":380,"width":62,"height":62}},
          {"AXUniqueId":null,"AXLabel":null,"AXValue":null,"type":"Group","role":"AXGroup",
           "enabled":true,"frame":{"x":0,"y":0,"width":402,"height":874}},
          {"AXUniqueId":"form.submit","AXLabel":"Envoyer","AXValue":null,"type":"Button",
           "role":"AXButton","enabled":false,
           "frame":{"x":16,"y":430,"width":370,"height":52}},
          {"AXUniqueId":"hidden.probe","AXLabel":"Probe","AXValue":null,"type":"Button",
           "role":"AXButton","enabled":true,
           "frame":{"x":10,"y":500,"width":0,"height":0}},
          {"AXUniqueId":"offscreen.next","AXLabel":"Next","AXValue":null,"type":"Button",
           "role":"AXButton","enabled":true,
           "frame":{"x":0,"y":1200,"width":402,"height":52}},
          {"AXUniqueId":"tab.explore","AXLabel":"Étude","AXValue":null,"type":"Button",
           "role":"AXButton","enabled":true,
           "frame":{"x":22,"y":781,"width":119,"height":44}}
        ]
        """

    /// `idb ui describe-point` answers with a single object, not an array.
    static let describePoint = """
        {"role_description":"button","enabled":true,"pid":100,"traits":["Button"],"title":null,
         "content_required":false,"frame":{"x":22,"y":781,"width":119,"height":44},
         "custom_actions":[],"AXUniqueId":"tab.explore","AXValue":null,"AXLabel":"Étude",
         "type":"Button","AXFrame":"{{22, 781}, {119, 44}}","help":null,"subrole":null,
         "role":"AXButton"}
        """

    /// What the companion says on the first call after a boot, before `idb connect`.
    static let noTranslationObject =
        "No translation object returned for simulator. This means you have likely specified a "
        + "point onscreen that is invalid or invisible due to a fullscreen dialog"
}
