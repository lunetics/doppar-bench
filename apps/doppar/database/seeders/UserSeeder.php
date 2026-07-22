<?php

namespace Database\Seeders;

use Phaseolies\Database\Migration\Seeder;
use App\Models\User;

class UserSeeder extends Seeder
{
    // Deterministic single row so /db returns identical data on every run and
    // across all three frameworks (id = 1, primary-key lookup target).
    public function run(): void
    {
        User::create([
            'name' => 'Benchmark User',
            'email' => 'bench@doppar-bench.test',
            'password' => bcrypt('benchmark'),
        ]);
    }
}
