package at.volkshilfe.nachbesuch.domain

import at.volkshilfe.nachbesuch.domain.map.ClusterGate
import at.volkshilfe.nachbesuch.domain.map.PinScale
import at.volkshilfe.nachbesuch.domain.map.PinScalePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

class MapRenderingTest {
    @Test fun scaleUsesAsymmetricHysteresis() {
        assertEquals(PinScale.FULL, PinScalePolicy.scaleFor(1_450.0, PinScale.FULL))
        assertEquals(PinScale.COMPACT, PinScalePolicy.scaleFor(1_600.0, PinScale.FULL))
        assertEquals(PinScale.COMPACT, PinScalePolicy.scaleFor(1_400.0, PinScale.COMPACT))
        assertEquals(PinScale.FULL, PinScalePolicy.scaleFor(1_250.0, PinScale.COMPACT))
    }

    @Test fun clusterGateHasDifferentOnAndOffThresholds() {
        val gate = ClusterGate()
        assertTrue(gate.update(3_100.0, 10))
        assertTrue(gate.update(2_500.0, 10))
        assertFalse(gate.update(1_900.0, 10))
    }
}
