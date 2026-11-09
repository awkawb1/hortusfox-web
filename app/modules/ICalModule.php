<?php

/**
 * Class ICalModule
 *
 * Builds RFC 5545 iCalendar (.ics) feeds for the workspace calendar and tasks
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
     * Wrap a list of already-built VEVENT line blocks in a VCALENDAR
     *
     * @param $eventLines
     * @param $workspaceName
     * @param $calname
     * @return string
     */
    private static function wrapCalendar($eventLines, $workspaceName, $calname)
    {
        $lines = [];
        $lines[] = 'BEGIN:VCALENDAR';
        $lines[] = 'VERSION:2.0';
        $lines[] = 'PRODID:-//HortusFox//' . $calname . '//EN';
        $lines[] = 'CALSCALE:GREGORIAN';
        $lines[] = 'METHOD:PUBLISH';
        $lines[] = 'X-WR-CALNAME:' . static::escapeText($workspaceName . ' - ' . $calname);

        foreach ($eventLines as $event) {
            $lines = array_merge($lines, $event);
        }

        $lines[] = 'END:VCALENDAR';

        return implode("\r\n", $lines) . "\r\n";
    }

    /**
     * Build the VEVENT line block for a single all-day event, spanning from
     * $date_from up to and including $date_till (both inclusive -- DTEND is
     * emitted as one day past $date_till, since iCal's all-day DTEND is
     * exclusive). Pass the same value for both to get a single-day event.
     *
     * @param $uid
     * @param $summary
     * @param $date_from
     * @param $date_till
     * @param $categories
     * @param $description
     * @return array
     */
    private static function buildAllDayEvent($uid, $summary, $date_from, $date_till, $categories = null, $description = null)
    {
        $host = $_SERVER['HTTP_HOST'] ?? 'hortusfox.local';

        $lines = [];
        $lines[] = 'BEGIN:VEVENT';
        $lines[] = 'UID:' . $uid . '@' . $host;
        $lines[] = 'DTSTAMP:' . gmdate('Ymd\THis\Z');
        $lines[] = 'DTSTART;VALUE=DATE:' . date('Ymd', strtotime($date_from));
        $lines[] = 'DTEND;VALUE=DATE:' . date('Ymd', strtotime('+1 day', strtotime($date_till)));
        $lines[] = 'SUMMARY:' . static::escapeText($summary);

        if (!empty($categories)) {
            $lines[] = 'CATEGORIES:' . static::escapeText($categories);
        }

        if (!empty($description)) {
            $lines[] = 'DESCRIPTION:' . static::escapeText($description);
        }

        $lines[] = 'END:VEVENT';

        return $lines;
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
        $events = [];

        foreach ($items as $item) {
            $events[] = static::buildAllDayEvent(
                'calendar-' . $item['id'],
                $item['name'],
                $item['date_from'],
                $item['date_till'],
                $item['class_name'] ?? null
            );
        }

        return static::wrapCalendar($events, $workspaceName, 'Calendar');
    }

    /**
     * Build a VCALENDAR feed from a list of TasksModel rows with a due date.
     * Recurring tasks have no fixed calendar pattern in this app -- due_date
     * is pushed forward relative to "now" by a cronjob once it passes, not a
     * deterministic RRULE series -- so each task is emitted as a single
     * occurrence at its *current* due_date; a client re-fetching the feed
     * after the cronjob runs picks up the new date automatically.
     *
     * @param $tasks
     * @param $workspaceName
     * @return string
     */
    public static function buildTaskFeed($tasks, $workspaceName)
    {
        $events = [];

        foreach ($tasks as $task) {
            $description = $task['description'] ?? null;

            if (!empty($task['plant_name'])) {
                $description = __('app.ical_task_plant_reference', ['plant' => $task['plant_name']]) . (($description) ? "\n\n" . $description : '');
            }

            $events[] = static::buildAllDayEvent(
                'task-' . $task['id'],
                $task['title'],
                $task['due_date'],
                $task['due_date'],
                __('app.tasks'),
                $description
            );
        }

        return static::wrapCalendar($events, $workspaceName, 'Tasks');
    }
}
