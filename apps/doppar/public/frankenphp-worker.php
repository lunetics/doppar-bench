<?php

// Experimental FrankenPHP worker entry point for Doppar.
//
// Doppar ships NO worker runtime of its own — `pool server:start` only launches
// PHP's built-in single-process dev server. This script tests whether Doppar can
// run in a real "boots once, stays in memory" worker model at all, by booting the
// application a single time and dispatching each incoming request against that
// same instance inside FrankenPHP's request loop.

ignore_user_abort(true);

require __DIR__ . '/../vendor/autoload.php';

// Boot the Doppar application ONCE (the defining property of worker mode).
$app = require __DIR__ . '/../bootstrap/app.php';

$handler = static function () use ($app): void {
    $response = $app->dispatch(\Phaseolies\Http\Request::capture());
    $response->terminate();
};

$maxRequests = (int) ($_SERVER['MAX_REQUESTS'] ?? 1000);
for ($n = 0, $running = true; $running && $n < $maxRequests; ++$n) {
    $running = \frankenphp_handle_request($handler);
    gc_collect_cycles();
}
