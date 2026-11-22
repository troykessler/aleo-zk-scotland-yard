// The 'test_scotlandyard' test program.
import scotlandyard.aleo;
program test_scotlandyard.aleo {
    @test
    @should_fail
    fn test_main_fails() {
        let result: u32 = scotlandyard.aleo::main(2u32, 3u32);
        assert_eq(result, 3u32);
    }

    @noupgrade
    constructor() {}
}
