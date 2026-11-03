package org.json

/** Host transport tokens, not a replacement JSON parser or wire-format test. */
class JSONObject {
    private val values: MutableMap<String, Any?>
    constructor(map: Map<*, *>) { values = map.entries.associate { it.key.toString() to it.value }.toMutableMap() }
    constructor(text: String) {
        values = if (text == "{}") mutableMapOf() else tokens[text]?.toMutableMap()
            ?: throw IllegalArgumentException("Malformed host JSON token")
    }
    fun keys(): MutableIterator<String> = values.keys.iterator()
    fun get(key: String): Any? = values.getValue(key)
    fun optInt(key: String, fallback: Int): Int = (values[key] as? Number)?.toInt() ?: fallback
    fun remove(key: String): Any? = values.remove(key)
    override fun toString(): String {
        val token = "host-json-${++next}"
        tokens[token] = values.toMap()
        return token
    }
    companion object {
        val NULL = Any()
        private val tokens = mutableMapOf<String, Map<String, Any?>>()
        private var next = 0
        fun reset() { tokens.clear(); next = 0 }
    }
}
class JSONArray(private val values: List<Any?>) {
    fun length() = values.size
    fun get(index: Int) = values[index]
}
