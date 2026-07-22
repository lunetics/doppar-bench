<?php

namespace Database\Seeders;

use App\Models\User;
use Illuminate\Database\Console\Seeds\WithoutModelEvents;
use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    use WithoutModelEvents;

    /**
     * Seed the application's database.
     */
    // Deterministic single row so /db returns identical data on every run and
    // matches the other frameworks (id = 1, primary-key lookup target).
    public function run(): void
    {
        User::create([
            'name'     => 'Benchmark User',
            'email'    => 'bench@doppar-bench.test',
            'password' => bcrypt('benchmark'),
        ]);
    }
}
