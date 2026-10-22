/* Verify the actual libcamera sensor helper, not a duplicate implementation. */
#include <cassert>
#include <cmath>
#include "libipa/camera_sensor_helper.h"
int main()
{
    auto helper = libcamera::ipa::CameraSensorHelperFactoryBase::create("imx681");
    assert(helper);
    assert(helper->gain(0) == 1.0);
    assert(helper->gain(512) == 2.0);
    assert(helper->gain(768) == 4.0);
    assert(helper->gain(960) == 16.0);
    for (unsigned int code = 0; code <= 960; code++) {
        double gain = helper->gain(code);
        unsigned int roundtrip = helper->gainCode(gain);
        assert(std::abs(static_cast<int>(roundtrip) - static_cast<int>(code)) <= 1);
        assert(gain >= 1.0 && gain <= 16.0);
        if (code) assert(gain > helper->gain(code - 1));
    }
    /* Do not invent a sensor black-level calibration. */
    assert(!helper->blackLevel().has_value());
}
