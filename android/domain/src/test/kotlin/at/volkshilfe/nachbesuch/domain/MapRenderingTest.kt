package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.map.PinScale
import at.volkshilfe.nachbesuch.domain.map.PinScalePolicy
import org.junit.Assert.assertEquals
import org.junit.Test

class MapRenderingTest {
    @Test fun scaleIsAFunctionOfCameraSpanOnly() {
        assertEquals(PinScale.FULL, PinScalePolicy.scaleFor(1_400.0))
        assertEquals(PinScale.COMPACT, PinScalePolicy.scaleFor(1_400.1))
        assertEquals(PinScale.COMPACT, PinScalePolicy.scaleFor(2_999.9))
        assertEquals(PinScale.DOT, PinScalePolicy.scaleFor(3_000.0))
    }
}
