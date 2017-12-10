/* Solver class for gnonograms
 * Finds solution for a set of clues.
 * Copyright (C) 2010-2017  Jeremy Wootten
 *
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *  Author:
 *  Jeremy Wootten <jeremywootten@gmail.com>
 */

namespace Gnonograms {
 public class Solver : GLib.Object {
    private Region[] regions;
    private uint n_regions;

    private Cell trial_cell;
    private int rdir;
    private int cdir;
    private int rlim;
    private int clim;
    private int turn;
    private uint max_turns;
    private uint guesses = 0;

    private bool should_check_solution;

    static uint MAX_PASSES = 200;
    /** PUBLIC **/

    public My2DCellArray grid {get; private set;}
    public My2DCellArray solution {get; private set;}
    private CellState[] grid_backup;

    public uint rows { get { return dimensions.height; }}
    public uint cols { get { return dimensions.width; }}
    private Dimensions _dimensions;
    public Dimensions dimensions {
        get {
            return _dimensions;
        }

        set {
            _dimensions = value;

            n_regions = rows + cols;

            grid = new My2DCellArray (value);
            solution = new My2DCellArray (value);
            regions = new Region[n_regions];

            for (int i = 0; i < n_regions; i++) {
                regions[i] = new Region (grid);
            }

            grid_backup =  new CellState[rows * cols];
        }
    }

    /** Set up solver for a particular puzzle. In addition to the clues, a starting point
      * and/or the correct solution may be provided (useful for debugging).
    **/
    public bool initialize (string[] row_clues,
                            string[] col_clues,
                            My2DCellArray? start_grid = null,
                            My2DCellArray? solution_grid = null) {

        assert (row_clues.length == rows && col_clues.length == cols);

        should_check_solution = solution_grid != null;

        if (should_check_solution) {
            solution.copy (solution_grid);
        }

        if (start_grid != null) {
            grid.copy (start_grid);
        } else {
            grid.set_all (CellState.UNKNOWN);
        }

        int index = 0;
        for (int r = 0; r < rows; r++) {
            regions[index++].initialize (r, false, cols, row_clues[r]);
        }

        for (int c = 0; c < cols; c++) {
            regions[index++].initialize (c, true, rows, col_clues[c]);
        }

        return valid ();
    }

    public bool valid () {
        foreach (Region r in regions) {
            if (r.in_error) {
                return false;
            }
        }

        int row_total = 0;
        int col_total = 0;

        for (int r = 0; r < rows; r++) {
            row_total += regions[r].block_total;
        }

        for (int c = 0; c < cols; c++) {
            col_total += regions[rows + c].block_total;
        }

        return row_total == col_total;
    }

    /** Initiate solving, specifying whether or not to use the advanced
      * procedures. Also specify whether in debugging mode and whether to solve one step
      * at a time (used for hinting if implemented).
    **/
    public int solve_it (Cancellable cancellable,
                         bool use_advanced,
                         bool unique_only,
                         bool advanced_only) {

        int result = simple_solver (should_check_solution);

        if (cancellable.is_cancelled ()) {
            return Gnonograms.FAILED_PASSES;
        }

        if (result > 0 && advanced_only) { // Do not want simple solutions
            return 0;
        }

        if (result == 0 && use_advanced) {
            result = advanced_solver (cancellable, unique_only);

            if (result < 0 || cancellable.is_cancelled ()) {
                return -1;
            }
        }

        return result;
    }

    public bool solved () {
        foreach (Region r in regions) {
            if (!r.is_completed) {
                return false;
            }
        }

        return true;
    }

    /** PRIVATE **/

    /** Returns -1 to indicate an error - TODO use throw error instead **/
    private int simple_solver (bool should_check_solution = false,  bool initialise = true) {
        if (initialise) {
            for (int i = 0; i < n_regions; i++) {
                regions[i].set_to_initial_state ();
            }
        }

        bool changed = true;
        int pass = 1;
        while (changed && pass >= 0 && pass < MAX_PASSES) {
            //keep cycling through regions while at least one of them is changing
            changed = false;

            foreach (Region r in regions) {
                if (r.is_completed) {
                    continue;
                }

                changed |= r.solve ();

                if (r.in_error) {
                    /* TODO Use conditional compilation to print out error if required */
                    pass = -2; // So still negative after increment
                    break;
                }
            }

            pass++;
        }

        solution.copy (grid);

        if (solved ()) {
        } else if (pass >= (int)MAX_PASSES) {
            pass = Gnonograms.FAILED_PASSES;
        } else  if (pass > 0) {
            pass = 0; // not solved and not in error
        }

        return pass;
    }

    private bool differs_from_solution (Region r) {
        bool is_column = r.is_column;
        uint index = r.index;
        int n_cells = r.n_cells;
        int solution_state;
        int region_state;

        for (uint i = 0; i < n_cells; i++) {
            region_state = r.get_cell_state (i);

            if (region_state == CellState.UNKNOWN) {
                continue;
            }

            solution_state = solution.get_data_from_rc (is_column ? i : index,
                                                        is_column ? index : i);

            if (solution_state == CellState.EMPTY) {
                if (region_state == CellState.EMPTY) {
                    continue;
                }
            } else { //solution_state is FILLED
                if (region_state != CellState.EMPTY) {
                    continue;
                }
            }

            return true;
        }

        return false;
    }

    /** Make single cell guesses, depth 1 (no recursion)
        Make a guess in each unknown cell in turn
        If it leads to contradiction mark opposite to guess,
        continue simple solve and if still no solution, continue with another guess.
        If first guess does not lead to solution leave unknown and choose another cell
    **/
    private int advanced_solver (Cancellable cancellable, bool unique_only = true) {
        int simple_result = 0;
        int wraps = 0;
        bool changed = false;
        bool solution_exists = false;
        bool ambiguous = false;
        int changed_count = 0;
        uint contradiction_count = 0;
        uint initial_max_turns = 3; //stay near edges until no more changes
        CellState initial_cell_state = CellState.EMPTY;

        var max_guesswork = 999;
        var grid_backup = new CellState[dimensions.area ()];

        rdir = 0;
        cdir = 1;
        rlim = (int)rows;
        clim = (int)cols;

        turn = 0;
        max_turns = initial_max_turns;

        this.save_position (grid_backup);
        trial_cell = { 0, uint.MAX, initial_cell_state };

        while (simple_result <= 0 && changed_count <= max_guesswork)  {
            contradiction_count = 0;
            solution_exists = false;
            ambiguous = true;
            trial_cell = make_guess (trial_cell);

            if (trial_cell.col == uint.MAX) { //run out of guesses
                if (max_turns == initial_max_turns) {
                    max_turns = (uint.min (rows, cols)) / 2 + 2; //ensure full coverage
                } else if (trial_cell.state == initial_cell_state) {
                    trial_cell = trial_cell.inverse (); //start making opposite guesses
                    max_turns = initial_max_turns;
                    wraps = 0;
                } else {
                    simple_result = 0;
                    break; //cannot make progress
                }

                rdir = 0;
                cdir = 1;
                rlim = (int)rows;
                clim = (int)cols;
                turn = 0;

                changed = false;

                wraps++;
                continue;
            }

            grid.set_data_from_cell (trial_cell);
            simple_result = simple_solver ();
            solution_exists = simple_result > 0;

            if (simple_result < 0) {
                contradiction_count++;
            }

            /* Try opposite to check whether ambiguous or unique */
            load_position (grid_backup); //back track
            changed = true;
            changed_count++; //worth trying another cycle
            var inverse = trial_cell.inverse ();

            grid.set_data_from_cell (inverse); //mark opposite to guess


            simple_result = simple_solver (false, false) ;// do not check solution or initialize

            int inverse_result = simple_result;
            if (simple_result == Gnonograms.FAILED_PASSES) {
                inverse_result = 0;
            } else if (simple_result < 0) {
                inverse_result = -1;
            }

            if (solution_exists) { // original guess was correct and yielded solution
                // regenerate original solution
                grid.set_data_from_cell (trial_cell);
                simple_solver ();
            }

            switch (inverse_result) {
                case -1:
                    if (contradiction_count > 0) {
                        critical ("error both ways");
                        return -1; // both guess contradictory (should not happen)

                    } else if (solution_exists) {
                        ambiguous = false;
                    }

                    break;

                case 0:
                    break;

                default:
                    // INVERSE guess yielded a solution.
                    if (contradiction_count > 0) {
                        // If both quesses yield a solution then puzzle is ambiguous
                        ambiguous = false;
                    }

                    solution_exists = true;
                    break;
            }

            if (!solution_exists) {
                load_position (grid_backup);
            } else if (unique_only && ambiguous) {
                simple_result = -1;
            }
        }

        //return vague measure of difficulty
        if (simple_result > 0) {
            return simple_result + changed_count * (ambiguous ? 10 : 2);
        }

        return simple_result;
    }

    /** Store the grid in linearised form **/
    private void save_position (CellState[] gs) {
        int index = 0;
        for (int r = 0; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
                gs[index++] = grid.get_data_from_rc (r, c);
            }
        }
    }

    private void load_position (CellState[] gs) {
        int index = 0;
        for (int r = 0; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
                grid.set_data_from_rc (r, c, gs[index++]);
            }
        }
    }

    /** Used by advanced solver. Scans in a spiral pattern from edges
      * as critical cells most likely in this region.
    **/
    private Cell make_guess (Cell cell) {
        int r = (int)(cell.row);
        int c = (int)(cell.col);

        while (true) {
            r += rdir;
            c += cdir; //only one changes at any one time

            if (cdir == 1 && c >= clim) {
                c--;
                cdir = 0;
                rdir = 1;
                r++;
            } else if (rdir == 1 && r >= rlim) { //across top  -  rh edge reached
                r--;
                rdir = 0;
                cdir = -1;
                c--;
            } else if (cdir == -1 && c < turn) { //down rh side  -  bottom reached
                c++;
                cdir = 0;
                rdir = -1;
                 r--;
            } else if (rdir == -1 && r <= turn) { //back across bottom lh edge reached
                r++;
                turn++;
                rlim--;
                clim--;
                rdir = 0;
                cdir = 1;
            } //up lh side  -  top edge reached

            if (turn > max_turns) { //stay near edge until no more changes
                cell.row = 0;
                cell.col = uint.MAX;
                break;
            }

            if (grid.get_data_from_rc (r, c) == CellState.UNKNOWN) {
                cell.row = (uint)r;
                cell.col = (uint)c;
                break;
            }
        }

        return cell;
    }
}
}
