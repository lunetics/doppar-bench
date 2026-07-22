<?php

use App\Models\User;
use Illuminate\Support\Facades\Route;

// Stateless benchmark routes. Registered via the `then:` callback in
// bootstrap/app.php OUTSIDE the web middleware group, so they carry no session,
// no cookies and no CSRF — a fair, stateless JSON/DB endpoint.

// Framework-overhead floor: static JSON, no database.
Route::get('/json', fn () => response()->json([
    'framework' => 'laravel',
    'endpoint'  => 'json',
    'ok'        => true,
    'items'     => [1, 2, 3],
]));

// Mirrors the vendor benchmark: a single primary-key lookup via Eloquent,
// returned as JSON (Eloquent models serialize to JSON automatically).
Route::get('/db', fn () => User::find(1));
