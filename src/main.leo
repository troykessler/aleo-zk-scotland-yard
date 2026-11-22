const MAP_MERKLE_ROOT_DEPTH: u8 = 9; // 2**9 = max 512 unique connections per map

const MISTERX_TICKETS_TAXI: u8 = 4;
const MISTERX_TICKETS_BUS: u8 = 3;
const MISTERX_TICKETS_UNDERGROUND: u8 = 3;
const MISTERX_TICKETS_CONCEALED: u8 = 4;
const MISTERX_TICKETS_DOUBLE_MOVE: u8 = 2;

const GAME_DETECTIVES: u8 = 4;

const DETECTIVE_TICKETS_TAXI: u8 = 10;
const DETECTIVE_TICKETS_BUS: u8 = 8;
const DETECTIVE_TICKETS_UNDERGROUND: u8 = 4;

const STARTING_POSITIONS: [u8; 18] = [13, 26, 29, 34, 50, 53, 91, 94, 103, 112, 117, 132, 138, 141, 155, 174, 197, 198];

struct Player {
    addr: address,

    position_trace: [u8; 24],
    ticket_trace: [u8; 24],

    tickets_taxi: u8,
    tickets_bus: u8,
    tickets_underground: u8,
    tickets_concealed: u8,
    tickets_double_move: u8,
}

struct Game {
    map_id: u64,

    misterx: Player,
    detectives: [Player; 4],
}

fn is_in_starting_positions(position: u8) -> bool {
    for i in 0u8..18u8 {
        if STARTING_POSITIONS[i] == position {
            return true;
        }
    }

    return false;
}

fn get_merkle_root(
    leaf_index: u16,
    siblings: [field; MAP_MERKLE_ROOT_DEPTH],
    from_position: u8,
    to_position: u8,
    transport_mask: u8,
) -> field {
    let low = from_position < to_position ? from_position : to_position;
    let high = from_position < to_position ? to_position : from_position;

    let current_hash = Poseidon4::hash_to_field([low, high, transport_mask]);

    let index = leaf_index;

    for i in 0u8..MAP_MERKLE_ROOT_DEPTH {
        let is_left = (index % 2u16) == 0u16;

        let left = is_left ? current_hash : siblings[i];
        let right = is_left ? siblings[i] : current_hash;

        current_hash = Poseidon4::hash_to_field([left, right]);
        index = index / 2u16;
    }

    // assert that provided leaf_index was indeed below 512
    assert_eq(index, 0u16);
    
    return current_hash;
}

program scotlandyard.aleo {
    storage game_counter: u64;
    storage map_counter: u64;

    mapping games: u64 => Game;
    mapping maps: u64 => field;

    record MisterXTrace {
        owner: address,
        game_id: u64,
        position_trace: [u8; 24],
    }
    
    @custom
    constructor() {
        if std::ctx::edition() > 0u16 {
            assert_eq(std::ctx::program_owner(), aleo1s04xz7v48t8jyf5kyzv5f080ctm3wfcrv0ezk2u0l863q79neuxsv2yg9n);
        }
    }

    fn publish_map(public map_root: field) -> Final {
        let caller: address = std::ctx::caller();

        assert_eq(caller, aleo1s04xz7v48t8jyf5kyzv5f080ctm3wfcrv0ezk2u0l863q79neuxsv2yg9n);

        return final {
            let map_id: u64 = map_counter.unwrap_or(0u64);
            maps.set(map_id, map_root);
            map_counter = map_id + 1;
        };
    }

    fn create_game(unverified_game_id: u64, misterx_start_position: u8, public map_id: u64, public detective: address) -> (MisterXTrace, Final) {
        let misterx: address = std::ctx::caller();
        assert_neq(misterx, detective);

        let misterx_position_trace = [0u8; 24];
        misterx_position_trace[0u8] = misterx_start_position;

        let misterx_trace = MisterXTrace {
            owner: misterx,
            game_id: unverified_game_id,
            position_trace: misterx_position_trace,
        };

        return (
            misterx_trace,
            final {
                let game_id: u64 = game_counter.unwrap_or(0u64);
                assert_eq(unverified_game_id, game_id);

                assert(maps.contains(map_id));

                games.set(game_id, Game {
                    map_id,

                    misterx: Player {
                        addr: misterx,

                        position_trace: [0u8; 24],
                        ticket_trace: [0u8; 24],

                        tickets_taxi: MISTERX_TICKETS_TAXI,
                        tickets_bus: MISTERX_TICKETS_BUS,
                        tickets_underground: MISTERX_TICKETS_UNDERGROUND,
                        tickets_concealed: MISTERX_TICKETS_CONCEALED,
                        tickets_double_move: MISTERX_TICKETS_DOUBLE_MOVE,
                    },
                    detectives: [Player {
                        addr: detective,

                        position_trace: [0u8; 24], // todo init proper detective start positions
                        ticket_trace: [0u8; 24],

                        tickets_taxi: DETECTIVE_TICKETS_TAXI,
                        tickets_bus: DETECTIVE_TICKETS_BUS,
                        tickets_underground: DETECTIVE_TICKETS_UNDERGROUND,
                        tickets_concealed: 0u8,
                        tickets_double_move: 0u8,
                    }; 4],
                });

                game_counter = game_id + 1;
            }
        );
    }

    fn move_misterx(
        public game_id: u64,
        public unverified_game: Game,
        misterx_trace: MisterXTrace,
        leaf_index: u16,
        siblings: [field; MAP_MERKLE_ROOT_DEPTH],
        to_position: u8,
        transport_mask: u8,
        public ticket: u8,
    ) -> (MisterXTrace, Final) {
        let misterx: address = std::ctx::caller();

        assert_eq(game_id, misterx_trace.game_id);

        let position_idx = 0u8;

        for i in 0u8..24u8 {
            if misterx_trace.position_trace[i] > 0u8 {
                position_idx = i;
            }
        }

        assert(position_idx < 24u8 - 1u8);

        let merkle_root = get_merkle_root(
            leaf_index,
            siblings,
            misterx_trace.position_trace[position_idx],
            to_position,
            transport_mask,
        )

        let updated_position_trace = misterx_trace.position_trace;
        updated_position_trace[position_idx + 1u8] = to_position;

        let updated_misterx_trace = MisterXTrace {
            owner: misterx_trace.owner,
            game_id: misterx_trace.game_id,
            position_trace: updated_position_trace,
        }

        // todo update onchain state of misterx ticket usage and possible reveals
    }
}
