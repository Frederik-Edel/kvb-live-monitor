package com.example.kvb_live_monitor

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject

class KvbDeparturesWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val preferences =
            context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        val stationName = preferences.getString(KEY_STATION, "KVB Abfahrten")
            ?: "KVB Abfahrten"
        val departures = JSONArray(preferences.getString(KEY_DEPARTURES, "[]"))
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId, stationName, departures)
        }
    }

    companion object {
        private const val PREFERENCES_NAME = "kvb_departures_widget"
        private const val KEY_STATION = "station_name"
        private const val KEY_DEPARTURES = "departures"

        fun update(
            context: Context,
            stationName: String,
            departures: List<Map<String, Any>>,
        ) {
            val departureJson = JSONArray()
            departures.forEach { departure ->
                departureJson.put(JSONObject(departure))
            }
            context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_STATION, stationName)
                .putString(KEY_DEPARTURES, departureJson.toString())
                .apply()

            val manager = AppWidgetManager.getInstance(context)
            val provider = ComponentName(context, KvbDeparturesWidgetProvider::class.java)
            val widgetIds = manager.getAppWidgetIds(provider)
            for (widgetId in widgetIds) {
                updateWidget(context, manager, widgetId, stationName, departureJson)
            }
        }

        private fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            stationName: String,
            departures: JSONArray,
        ) {
            val views = RemoteViews(context.packageName, R.layout.kvb_departures_widget)
            views.setTextViewText(R.id.widget_station_name, stationName)

            val rows = mutableListOf<String>()
            for (index in 0 until minOf(departures.length(), 5)) {
                val departure = departures.optJSONObject(index) ?: continue
                val prefix = if (departure.optBoolean("cancelled")) "X " else ""
                rows.add(
                    "$prefix${departure.optString("line")}  " +
                        "${departure.optString("time")}  " +
                        departure.optString("destination"),
                )
            }
            views.setTextViewText(
                R.id.widget_departures,
                if (rows.isEmpty()) "Keine Abfahrten verfügbar" else rows.joinToString("\n"),
            )

            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            }
            manager.updateAppWidget(widgetId, views)
        }
    }
}
