package com.fluentplayer.audit.controls;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Exercises the same bounded traversal used by the Android instrumentation, without Android. */
public final class NotificationTitleSearchTest {
    private static int checks;
    private static void check(boolean value) {
        checks++;
        if (!value) throw new AssertionError("Title search check " + checks + " failed");
    }
    private static final class Node {
        String id, pkg = NotificationExpandPolicy.SYSTEM_UI, text;
        boolean visible = true, refresh = true, throwsText;
        int reads, retains, releases;
        List<Node> children = new ArrayList<>();
        Node(String id, String text, Node... children) {
            this.id = id; this.text = text; this.children.addAll(Arrays.asList(children));
        }
    }
    private static final class Tree implements NotificationTitleSearch.Tree<Node> {
        long clock, tick;
        public long now() { long value = clock; clock += tick; return value; }
        public String viewId(Node node) { return node.id; }
        public String packageName(Node node) { return node.pkg; }
        public boolean visible(Node node) { return node.visible; }
        public boolean refresh(Node node) { return node.refresh; }
        public CharSequence text(Node node) {
            node.reads++;
            if (node.throwsText) throw new IllegalStateException("private source value");
            return node.text;
        }
        public int childCount(Node node) { return node.children.size(); }
        public Node child(Node node, int index) { return node.children.get(index); }
        public Node retain(Node node) { node.retains++; return node; }
        public void release(Node node) { node.releases++; }
    }
    private static Node title(String text) { return new Node("com.android.systemui:id/title", text); }
    public static void main(String[] args) {
        Tree tree = new Tree();
        Node known = title(NotificationExpandPolicy.TITLE), other = title("unrelated private title");
        Node body = new Node("com.android.systemui:id/text", "private body must never be read");
        Node root = new Node("root", "root must not be read", other, body, known);
        NotificationTitleSearch.Result<Node> result = NotificationTitleSearch.find(tree, root);
        check(result.complete && result.exact == 1 && result.titleFields == 2 && result.visited == 4);
        check(result.selected == known && known.retains == 1 && other.retains == 0);
        check(other.reads == 1 && known.reads == 1 && root.reads == 0 && body.reads == 0);
        result.close(tree);
        check(result.selected == null);

        Node duplicate = title(NotificationExpandPolicy.TITLE);
        result = NotificationTitleSearch.find(tree, new Node("root", null, known, duplicate));
        check(result.complete && result.exact == 2); result.close(tree);
        Node partial = title(NotificationExpandPolicy.TITLE + " suffix");
        result = NotificationTitleSearch.find(tree, new Node("root", null, partial));
        check(result.complete && result.exact == 0 && result.selected == null && partial.retains == 0);

        Node foreign = title("private other package"); foreign.pkg = "com.example.other";
        Node hidden = title("private hidden title"); hidden.visible = false;
        result = NotificationTitleSearch.find(tree, new Node("root", null, foreign, hidden, known));
        check(result.complete && result.exact == 1 && foreign.reads == 0 && hidden.reads == 0); result.close(tree);

        result = NotificationTitleSearch.find(tree, root, 2, 80, 400);
        check(!result.complete && result.selected == null);
        Node parent = new Node("root", null, new Node("nested", null, known));
        result = NotificationTitleSearch.find(tree, parent, 100, 1, 400);
        check(!result.complete && result.exact == 0);
        Tree slow = new Tree(); slow.tick = 150;
        result = NotificationTitleSearch.find(slow, root, 100, 80, 200);
        check(!result.complete && result.selected == null);

        result = NotificationTitleSearch.find(tree, new Node("root", null, known, (Node)null));
        check(!result.complete && result.exact == 1); result.close(tree);
        Node unavailable = title("unavailable private title"); unavailable.refresh = false;
        result = NotificationTitleSearch.find(tree, new Node("root", null, unavailable, known));
        check(!result.complete && result.refreshFailures == 1 && unavailable.reads == 0);

        Node throwing = title("secret"); throwing.throwsText = true;
        int retainedBefore = known.retains, releasedBefore = known.releases;
        try {
            NotificationTitleSearch.find(tree, new Node("root", null, known, throwing));
            throw new AssertionError("Expected controlled adapter exception");
        } catch (IllegalStateException expected) {
            check(known.retains == retainedBefore + 1);
            check(known.releases == releasedBefore + 2); // visited child plus retained match cleanup
        }
        System.out.println("NotificationTitleSearch: " + checks + " checks passed; complete bounded traversal, exact match, numeric-only result, no Android runtime/device accessed.");
    }
}
