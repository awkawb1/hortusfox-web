<?php

/**
 * Class ICalModule
 *
 * Builds RFC 5545 iCalendar (.ics) feeds for the workspace calendar
 */
class ICalModule {
    /**
     * Escape a text value per RFC 5545 (backslash, semicolon, comma, newline)
     *
     * @param $text
     * @return string
     */
    private static function escapeText($text)
    {
        $text = str_replace('\\', '\\\\', $text);
        $text = str_replace(';', '\\;', $text);
        $text = str_replace(',', '\\,', $text);
        $text = str_replace(["\r\n", "\n"], '\\n', $text);

        return $text;
    }

    /**
     * Build a VCALENDAR feed from a list of CalendarModel rows
     *
     * @param $items
     * @param $workspaceName
     * @return string
     */
    public static function buildFeed($items, $workspaceName)
    {
        $host = $_SERVER['HTTP_HOST'] ?? 'hortusfox.local';

        $lines = [];
        $lines[] = 'BEGIN:VCALENDAR';
        $lines[] = 'VERSION:2.0';
        $lines[] = 'PRODID:-//HortusFox//Calendar//EN';
        $lines[] = 'CALSCALE:GREGORIAN';
        $lines[] = 'METHOD:PUBLISH';
        $lines[] = 'X-WR-CALNAME:' . static::escapeText($workspaceName);

        foreach ($items as $item) {
            $date_from = date('Ymd', strtotime($item['date_from']));
            $date_till = date('Ymd', strtotime('+1 day', strtotime($item['date_till'])));

            $lines[] = 'BEGIN:VEVENT';
            $lines[] = 'UID:calendar-' . $item['id'] . '@' . $host;
            $lines[] = 'DTSTAMP:' . gmdate('Ymd\THis\Z');
            $lines[] = 'DTSTART;VALUE=DATE:' . $date_from;
            $lines[] = 'DTEND;VALUE=DATE:' . $date_till;
            $lines[] = 'SUMMARY:' . static::escapeText($item['name']);

            if (!empty($item['class_name'])) {
                $lines[] = 'CATEGORIES:' . static::escapeText($item['class_name']);
            }

            $lines[] = 'END:VEVENT';
        }

        $lines[] = 'END:VCALENDAR';

        return implode("\r\n", $lines) . "\r\n";
    }
}
