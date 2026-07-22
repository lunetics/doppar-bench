<?php

namespace App\Http\Controllers;

use App\Http\Controllers\Controller;
use App\Models\User;
use Phaseolies\Utilities\Attributes\Route;

class BenchController extends Controller
{
    // Framework-overhead floor: no database, just a small static JSON payload
    // routed and serialized by the framework.
    #[Route(uri: '/json', name: 'bench.json')]
    public function json()
    {
        return response()->json([
            'framework' => 'doppar',
            'endpoint'  => 'json',
            'ok'        => true,
            'items'     => [1, 2, 3],
        ]);
    }

    // Mirrors the vendor benchmark route exactly: a single primary-key lookup
    // through the framework's ORM, returned as JSON.
    #[Route(uri: '/db', name: 'bench.db')]
    public function db()
    {
        return User::find(1);
    }
}
